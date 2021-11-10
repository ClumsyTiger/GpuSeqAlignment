#include <cstdio>
#include <cooperative_groups.h>
#include "omp.h"
#include "Common.h"


// cuda kernel A for the parallel implementation
// +   initializes the score matrix in the gpu
__global__ static void kernelA( int* seqX_gpu, int* seqY_gpu, int* score_gpu, int rows, int cols, int (*blosum62_gpu)[BLOSUMSZ], int insdelcost )
{
   // the blosum matrix and relevant parts of the two sequences
   // +   stored in shared memory for faster random access
   __shared__ int blosum62[BLOSUMSZ][BLOSUMSZ];
   __shared__ int seqX[tileAx];
   __shared__ int seqY[tileAy];

   // initialize the blosum shared memory copy
   {
      // map the threads from the thread block onto the blosum matrix elements
      int i = threadIdx.y*BLOSUMSZ + threadIdx.x;
      // while the current thread maps onto an element in the matrix
      while( i < BLOSUMSZ*BLOSUMSZ )
      {
         // copy the current element from the global blosum matrix
         blosum62[ 0 ][ i ] = blosum62_gpu[ 0 ][ i ];
         // map this thread to the next element with stride equal to the number of threads in this block
         i += tileAy*tileAx;
      }
   }

   // initialize the X and Y sequences' shared memory copies
   {
      // position of the current thread in the global X and Y sequences
      int x = blockIdx.x*blockDim.x;
      int y = blockIdx.y*blockDim.y;
      // map the threads from the first            row  to the shared X sequence part
      // map the threads from the second and later rows to the shared Y sequence part
      int iX = ( threadIdx.y     )*tileAx + threadIdx.x;
      int iY = ( threadIdx.y - 1 )*tileAx + threadIdx.x;

      // if the current thread maps to the first row, initialize the corresponding element
      if( iX < tileAx )        seqX[ iX ] = seqX_gpu[ x + iX ];
      // otherwise, remap it to the first column and initialize the corresponding element
      else if( iY < tileAy )   seqY[ iY ] = seqY_gpu[ y + iY ];
   }
   
   // make sure that all threads have finished initializing their corresponding elements
   __syncthreads();

   // initialize the score matrix in global memory
   {
      // position of the current thread in the score matrix
      int i = blockIdx.y*blockDim.y + threadIdx.y;
      int j = blockIdx.x*blockDim.x + threadIdx.x;
      // position of the current thread in the sequences
      int iX = threadIdx.x;
      int iY = threadIdx.y;
      // the current element value
      int elem = 0;
      
      // if the current thread is outside the score matrix, return
      if( i >= rows || j >= cols ) return;

      // if the current thread is not in the first row or column of the score matrix
      // +   use the blosum matrix to calculate the score matrix element value
      // +   increase the value by insert delete cost, since then the formula for calculating the actual element value in kernel B becomes simpler
      if( i > 0 && j > 0 ) { elem = blosum62[ seqY[iY] ][ seqX[iX] ] + insdelcost; }
      // otherwise, if the current thread is in the first row or column
      // +   update the score matrix element using the insert delete cost
      else                 { elem = -( i|j )*insdelcost; }
      
      // update the corresponding element in global memory
      // +   fully coallesced memory access
      el(score_gpu,cols, i,j) = elem;
   }
}


// cuda kernel B for the parallel implementation
// +   calculates the score matrix in the gpu using the initialized score matrix from kernel A
// +   the given matrix minus the padding (zeroth row and column) must be evenly divisible by the tile B
__global__ static void kernelB( int* score_gpu, int trows, int tcols, int insdelcost )
{
   // matrix tile which this thread block maps onto
   // +   stored in shared memory for faster random access
   __shared__ int tile[1+tileBy][1+tileBx];

   
   //    |/ / / . .   +   . . . / /   +   . . . . .|/ /
   //   /|/ / . . .   +   . . / / .   +   . . . . /|/
   // / /|/ . . . .   +   . / / . .   +   . . . / /|

   // for all diagonals of tiles in the grid of tiles (score matrix)
   for( int s = 0;   s < tcols-1 + trows;   s++ )
   {
      // (s,t) -- tile coordinates in the grid of tiles (score matrix)
      int tbeg = max( 0, s - (tcols-1) );
      int tend = min( s, trows-1 );


      // map a tile on the current diagonal of tiles to this thread block
      // +   then go to the next tile on the diagonal with stride equal to the number of thread blocks in the thread grid
      for( int t = tbeg + blockIdx.x;   t <= tend;   t += gridDim.x )
      {
         // initialize the score matrix tile
         {
            // position of the top left element of the current tile in the score matrix
            int ibeg = ( 1 + (   t )*tileBy ) - 1;
            int jbeg = ( 1 + ( s-t )*tileBx ) - 1;
            // the number of colums in the score matrix
            int cols = 1 + tcols*tileBx;

            // current thread position in the tile
            int i = threadIdx.x / ( tileBx+1 );
            int j = threadIdx.x % ( tileBx+1 );
            // stride on the current thread position in the tile, equal to the number of threads in this thread block
            // +   it is split into row and column increments for the tread's position for performance reasons (avoids using division and modulo operator in the inner cycle)
            int di = blockDim.x / ( tileBx+1 );
            int dj = blockDim.x % ( tileBx+1 );
            
            // while the current thread maps onto an element in the tile
            while( i < ( 1+tileBy ) )
            {
               // copy the current element from the global score matrix to the tile
               tile[ i ][ j ] = el(score_gpu,cols, ibeg+i,jbeg+j);

               // map the current thread to the next tile element
               i += di; j += dj;
               // if the column index is out of bounds, increase the row index by one and wrap around the column index
               if( j >= ( 1+tileBx ) ) { i++; j -= ( 1+tileBx ); }
            }
         }

         // all threads in this block should finish initializing this tile in shared memory
         __syncthreads();
         
         // calculate the tile elements
         // +   only threads in the first warp from this block are active here, other warps have to wait
         if( threadIdx.x < WARPSZ )
         {
            // the number of rows and colums in the tile without its first row and column (the part of the tile to be calculated)
            int rows = tileBy;
            int cols = tileBx;

            //    |/ / / . .   +   . . . / /   +   . . . . .|/ /
            //   /|/ / . . .   +   . . / / .   +   . . . . /|/
            // / /|/ . . . .   +   . / / . .   +   . . . / /|

            // for all diagonals in the tile without its first row and column
            for( int d = 0;   d < cols-1 + rows;   d++ )
            {
               // (d,p) -- element coordinates in the tile
               int tbeg = max( 0, d - (cols-1) );
               int tend = min( d, rows-1 );
               // position of the current thread's element on the tile diagonal
               int p = tbeg + threadIdx.x;

               // if the thread maps onto an element on the current tile diagonal
               if( p <= tend )
               {
                  // position of the current element
                  int i = 1 + (   p );
                  int j = 1 + ( d-p );
                  
                  // calculate the current element's value
                  // +   always subtract the insert delete cost from the result, since the kernel A added that value to each element of the score matrix
                  int temp1  =      tile[i-1][j-1] + tile[i  ][j  ];
                  int temp2  = max( tile[i-1][j  ] , tile[i  ][j-1] );
                  tile[i][j] = max( temp1, temp2 ) - insdelcost;
               }

               // all threads in this warp should finish calculating the tile's current diagonal
               __syncwarp();
            }
         }
         
         // all threads in this block should finish calculating this tile
         __syncthreads();
         

         // save the score matrix tile
         {
            // position of the first (top left) calculated element of the current tile in the score matrix
            int ibeg = ( 1 + (   t )*tileBy );
            int jbeg = ( 1 + ( s-t )*tileBx );
            // the number of colums in the score matrix
            int cols = 1 + tcols*tileBx;

            // current thread position in the tile
            int i = threadIdx.x / tileBx;
            int j = threadIdx.x % tileBx;
            // stride on the current thread position in the tile, equal to the number of threads in this thread block
            // +   it is split into row and column increments for the tread's position for performance reasons (avoids using division and modulo operator in the inner cycle)
            int di = blockDim.x / tileBx;
            int dj = blockDim.x % tileBx;
            
            // while the current thread maps onto an element in the tile
            while( i < tileBy )
            {
               // copy the current element from the tile to the global score matrix
               el(score_gpu,cols, ibeg+i,jbeg+j) = tile[ 1+i ][ 1+j ];

               // map the current thread to the next tile element
               i += di; j += dj;
               // if the column index is out of bounds, increase the row index by one and wrap around the column index
               if( j >= tileBx ) { i++; j -= tileBx; }
            }
         }
         
         // all threads in this block should finish saving this tile
         // +   block synchronization unnecessary since the tiles on the current diagonal are independent
      }

      // all threads in this grid should finish calculating the diagonal of tiles
      cooperative_groups::this_grid().sync();
   }
}


// parallel gpu implementation of the Needleman Wunsch algorithm
int GpuParallel1( const int* seqX, const int* seqY, int* score, int rows, int cols, int adjrows, int adjcols, int insdelcost, float* time, float* ktime )
{
   // check if the given input is valid, if not return
   if( !seqX || !seqY || !score || !time || !ktime ) return false;
   if( rows <= 1 || cols <= 1 ) return false;

   // start the host timer and initialize the gpu timer
   *time = omp_get_wtime();
   *ktime = 0;

   // blosum matrix, sequences which will be compared and the score matrix stored in gpu global memory
   int *blosum62_gpu, *seqX_gpu, *seqY_gpu, *score_gpu;
   // allocate space in the gpu global memory
   cudaMalloc( &seqX_gpu,     adjcols           * sizeof( int ) );
   cudaMalloc( &seqY_gpu,     adjrows           * sizeof( int ) );
   cudaMalloc( &score_gpu,    adjrows*adjcols   * sizeof( int ) );
   cudaMalloc( &blosum62_gpu, BLOSUMSZ*BLOSUMSZ * sizeof( int ) );
   // copy data from host to device
	cudaMemcpy( seqX_gpu,     seqX,     adjcols           * sizeof( int ), cudaMemcpyHostToDevice );
	cudaMemcpy( seqY_gpu,     seqY,     adjrows           * sizeof( int ), cudaMemcpyHostToDevice );
	cudaMemcpy( blosum62_gpu, blosum62, BLOSUMSZ*BLOSUMSZ * sizeof( int ), cudaMemcpyHostToDevice );
   // create events for measuring kernel execution time
   cudaEvent_t start, stop;
   cudaEventCreate( &start );
   cudaEventCreate( &stop );


   printf("   - processing score matrix in a blocky diagonal fashion\n");


   // launch kernel A
   {
      // calculate grid dimensions for kernel A
      dim3 gridA;
      gridA.y = ceil( float( adjrows )/tileAy );
      gridA.x = ceil( float( adjcols )/tileAx );
      // block dimensions for kernel A
      dim3 blockA { tileAx, tileAy };
      
      // launch the kernel in the given stream (don't statically allocate shared memory)
      // +   capture events around kernel launch as well
      // +   update the stop event when the kernel finishes
      cudaEventRecord( start, STREAM_ID );
      kernelA<<< gridA, blockA, 0, STREAM_ID >>>( seqX_gpu, seqY_gpu, score_gpu, adjrows, adjcols, ( int (*)[BLOSUMSZ] )blosum62_gpu, insdelcost );
      cudaEventRecord( stop, STREAM_ID );
      cudaEventSynchronize( stop );
      
      // kernel A execution time
      float ktimeA;
      // calculate the time between the given events
      cudaEventElapsedTime( &ktimeA, start, stop );
      // update the total kernel execution time
      *ktime += ktimeA;
   }
   
   // wait for the gpu to finish before going to the next step
   cudaDeviceSynchronize();


   // launch kernel B
   {
      // grid and block dimensions for kernel B
      dim3 gridB;
      dim3 blockB;
      // the number of tiles per row and column of the score matrix
      int trows = ceil( float( adjrows-1 )/tileBy );
      int tcols = ceil( float( adjcols-1 )/tileBx );
      
      // calculate grid and block dimensions for kernel B
      {
         // take the number of warps on the largest tile diagonal times the number of threads in a warp as the number of threads
         // +   also multiply by the number of half warps in the larger dimension for faster writing to global gpu memory
         blockB.x  = ceil( min( tileBy, tileBx )*1./WARPSZ )*WARPSZ;
         blockB.x *= ceil( max( tileBy, tileBx )*2./WARPSZ );
         // take the number of tiles on the largest score matrix diagonal as the only dimension
         gridB.x = min( trows, tcols );

         // the maximum number of parallel blocks on a streaming multiprocessor
         int maxBlocksPerSm = 0;
         // number of threads per block that the kernel will be launched with
         int numThreads = blockB.x;
         // size of shared memory per block in bytes
         int sharedMemSz = ( ( 1+tileBy )*( 1+tileBx ) )*sizeof( int );

         // calculate the max number of parallel blocks per streaming multiprocessor
         cudaOccupancyMaxActiveBlocksPerMultiprocessor( &maxBlocksPerSm, kernelB, numThreads, sharedMemSz );
         // the number of cooperative blocks launched must not exceed the maximum possible number of parallel blocks on the device
         gridB.x = min( gridB.x, MPROCS*maxBlocksPerSm );
      }

      // group arguments to be passed to kernel B
      void* kargs[] { &score_gpu, &trows, &tcols, &insdelcost };
      
      // launch the kernel in the given stream (don't statically allocate shared memory)
      // +   capture events around kernel launch as well
      // +   update the stop event when the kernel finishes
      cudaEventRecord( start, STREAM_ID );
      cudaLaunchCooperativeKernel( ( void* )kernelB, gridB, blockB, kargs, 0, STREAM_ID );
      cudaEventRecord( stop, STREAM_ID );
      cudaEventSynchronize( stop );
      
      // kernel B execution time
      float ktimeB;
      // calculate the time between the given events
      cudaEventElapsedTime( &ktimeB, start, stop );
      // update the total kernel execution time
      *ktime += ktimeB;
   }

   // wait for the gpu to finish before going to the next step
   cudaDeviceSynchronize();
   // save the calculated score matrix
   // +   waits for the device to finish, then copies data from device to host
   cudaMemcpy( score, score_gpu, adjrows*adjcols * sizeof( int ), cudaMemcpyDeviceToHost );

   // stop the timer
   *time = ( omp_get_wtime() - *time );

   
   // free allocated space in the gpu global memory
   cudaFree( seqX_gpu );
   cudaFree( seqY_gpu );
   cudaFree( score_gpu );
   cudaFree( blosum62_gpu );
   // free events' memory
   cudaEventDestroy( start );
   cudaEventDestroy( stop );

   // return that the operation is successful
   return true;
}






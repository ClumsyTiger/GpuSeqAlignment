#include <chrono>
#include "Common.h"


// parallel cpu implementation of the Needleman Wunsch algorithm
void CpuParallel( NWArgs& nw, NWResult& res, Stopwatch& sw )
{
   // start the timer
   sw.startTimer();


   // skip the first row and first column in the next calculations
   nw.rows--; nw.cols--;

   // initialize the first row and column of the score matrix
   #pragma omp parallel
   {
      #pragma omp for schedule( static ) nowait
      for( int i = 0; i < 1+nw.rows; i++ ) el(nw.score,nw.adjcols, i,0) = -i*nw.insdelcost;
      #pragma omp for schedule( static )
      for( int j = 0; j < 1+nw.cols; j++ ) el(nw.score,nw.adjcols, 0,j) = -j*nw.insdelcost;

      #pragma omp single
      {
         // printf("   - processing score matrix in a blocky diagonal fashion\n");
      }
      
      // size of block that will be a unit of work
      // +   8*16 ints on standard architectures, or 8 cache lines
      const int bsize = 8 * 64/*B*//sizeof( int );
      
      // number of blocks in a row and column (rounded up)
      const int brows = ceil( 1.*nw.rows / bsize );
      const int bcols = ceil( 1.*nw.cols / bsize );


      //  / / / . .   +   . . . / /   +   . . . . .|/ /
      //  / / . . .   +   . . / / .   +   . . . . /|/
      //  / . . . .   +   . / / . .   +   . . . / /|
      for( int s = 0; s < bcols-1 + brows; s++ )
      {
         int tbeg = max2( 0, s - (bcols-1) );
         int tend = min2( s, brows-1 );

         #pragma omp for schedule( static )
         for( int t = tbeg; t <= tend; t++ )
         {
            // calculate the block boundaries
            int ibeg = 1 + (   t )*bsize;
            int jbeg = 1 + ( s-t )*bsize;

            int iend = min2( ibeg + bsize, 1+nw.rows );
            int jend = min2( jbeg + bsize, 1+nw.cols );

            // process the block
            for( int i = ibeg; i < iend; i++ )
            for( int j = jbeg; j < jend; j++ )
            {
               UpdateScore( nw.seqX, nw.seqY, nw.score, nw.adjrows, nw.adjcols, nw.insdelcost, i, j );
            }
         }
      }
   }

   // restore the original row and column count
   nw.rows++; nw.cols++;

   // stop the timer
   sw.addLap( "Tcpu" );
   sw.stopTimer();
   res.Tcpu = sw.getLap( "Tcpu" ) / 1000.;
}






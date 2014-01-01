
/*
 *   The breadth-first search algorithm
 *
 *   Copyright (C) 2013-2014 by
 *   Cheng Yichao        onesuperclark@gmail.com
 *
 *   This program is free software; you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation; either version 2 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 */


#pragma once
 
#include "cuda_util.cuh"
#include "util.cuh"
#include <cuda_runtime_api.h>

#define INF -1

/**
 * each thread wakeup and check if activated[tid] == 1
 * using update[] to mark unvisited vertices in this round
 */
template<typename VertexId, typename SizeT, typename Value>
__global__ void
BFSKernel_expand(SizeT     max_size,
		         SizeT     *row_offsets,
                 VertexId  *column_indices,
                 int       *activated,
                 Value     *levels,
                 int       *visited,
                 int       *update)
{
	int tid = blockIdx.x * blockDim.x + threadIdx.x;


	if (tid < max_size) {

		if (activated[tid] == 1) {

			activated[tid] = 0;     // wakeup only once
			SizeT outEdgeFirst = row_offsets[tid];
			SizeT outEdgeLast = row_offsets[tid+1];

			for (SizeT edge = outEdgeFirst; edge < outEdgeLast; edge++) {

				VertexId inNode = column_indices[edge];
				if (visited[inNode] == 0) {
					levels[inNode] = levels[tid] + 1;
					update[inNode] = 1;
				}
			}
		}
	}
}


/**
 * use update[] to mask activated[]
 */
template<typename VertexId, typename SizeT>
__global__ void
BFSKernel_update(SizeT     max_size,
		         SizeT     *row_offsets,
                 VertexId  *column_indices,
                 int       *activated,
                 int       *visited,
                 int       *update,
                 int       *terminate)
{
	int tid =  blockIdx.x * blockDim.x + threadIdx.x;


	if (tid < max_size) {

		if (update[tid] == 1) {

			activated[tid] = 1;     
			update[tid] = 0;     // clear after activating
			visited[tid] = 1;   
			// as long as one thread try to set it false
			// the while loop will not be terminated 
			*terminate = 0; 
		}
	}
}


template<typename VertexId, typename SizeT, typename Value>
void BFSGraph_gpu_bitmask(graph<VertexId, SizeT, Value> &g, VertexId source)
{

	// use a list to represent bitmask
    list<int, SizeT> activated(g.n);
    list<int, SizeT> update(g.n);
    activated.all_to(0);
    update.all_to(0);

    // Initalize auxiliary list
    list<Value, SizeT> levels(g.n);
    levels.all_to(INF);

    // visitation
    list<int, SizeT> visited(g.n);
    visited.all_to(0);

    // set up a flag, initially set
    var<int> terminate;
    terminate.set(0);

	// traverse from source node
    activated.set(source, 1);
    levels.set(source, 0);
    visited.set(source, 1);
	Value curLevel = 0;


	// kernel configuration
	int blockSize = 256;
	// spawn as many threads as the vertices in the graph
	int blockNum = (g.n % blockSize == 0 ? 
		g.n / blockSize :
		g.n / blockSize + 1);

	printf("gpu bitmasked bfs starts\n");	

	// loop as long as the flag is set
	while (terminate.getVal() == 0) {

		// set true at first, if no vertex has been expanded
		// the while loop will be terminated
		terminate.set(1);

		// kick off timer first
		GpuTimer gpu_timer;
		gpu_timer.start();

		BFSKernel_expand<<<blockNum, blockSize>>>(g.n,
				                                  g.d_row_offsets,
				            	                  g.d_column_indices,
				                                  activated.d_elems,
				                                  levels.d_elems,             
				                                  visited.d_elems,
				                                  update.d_elems);
		if (HandleError(cudaThreadSynchronize(), "BFSKernel_expand failed ", __FILE__, __LINE__)) break;

		BFSKernel_update<<<blockNum, blockSize>>>(g.n,
											      g.d_row_offsets,
				            	                  g.d_column_indices,
				                                  activated.d_elems,
				                                  visited.d_elems,
				                                  update.d_elems,     
				                                  terminate.d_elem);
		if (HandleError(cudaThreadSynchronize(), "BFSKernel_update failed ", __FILE__, __LINE__)) break;


		 // timer end
		 gpu_timer.stop();

		 printf("%d\t%f\n", curLevel, gpu_timer.elapsedMillis());
		 curLevel += 1;

	}
    
    printf("gpu bitmasked bfs terminates\n");	


    levels.print_log();

    levels.del();
    visited.del();
    activated.del();
	update.del();
	terminate.del();
	
}
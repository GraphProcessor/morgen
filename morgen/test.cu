/*
 *   For testing
 *
 *   Copyright (C) 2013-2014 by
 *   Yichao Cheng        onesuperclark@gmail.com
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



#include <morgen/graph/csr_graph.cuh>
#include <morgen/graph/gen/mine.cuh>
#include <morgen/graph/gen/dimacs.cuh>
#include <morgen/graph/gen/coo.cuh>
#include <morgen/bfs/bitmask.cu>
#include <morgen/bfs/queue.cu>
#include <morgen/bfs/hash.cu>
#include <morgen/bfs/topo.cu>
#include <morgen/bfs/serial.cu>
#include <morgen/utils/stats.cuh>
#include <morgen/utils/command_line.cuh>
#include <morgen/utils/random_node.cuh>
#include <morgen/utils/utilizing_efficiency.cuh>


using namespace morgen;


void usage() {
    printf("\ntest <graph> <bfs type> [--device=<device index>] "
            "[--slots=<number of slots>] [--outdegree=log|uniform] [--distribution] [--workset]"
            "[--src=<source idx>|random] [--instrument] "
            "[--ordered]"
            "[--group_size=<group size>]\n"
            "\n"
            "<graph>\n"
            "    tiny: tiny graph for debugging\n"
            "    fla: Florida Road map\n"
            "    mesh: 6-point 2D mesh\n"
            "    kkt: Optimal power flow, nonlinear optimization (KKT)\n"
            "    copaper: CopaperCiteSeer\n"
            "    audi: symmetric rb matrix\n"
            "    rmat1: random small world graph (n=5M  m=60M)\n"
            "    rmat2: random small world graph (n=2M  n=100M)\n"
            "    amazon: Amazon product co-buying\n"
            "    random1: Erdos-Renyi or uniformly random graph (n=5M n=60M)\n"
            "    random2: Erdos-Renyi or uniformly random graph (n=2M n=100M)\n"
            "    eco: circuit theory applied to animal/gene flow\n"
            "    thermal: FEM 3D nonlinear thermal problem, 8-node bricks as volume elements\n"
            "    livejournal: LiveJournal's social network\n"
            "<bfs type>\n"
            "\n"
            "     serial: \n"
            "     queue: \n"
            "     hash: \n"
            "     bitmask: \n"
            "\n"
            "--outdegree=log|uniform\n"
            "    print out degrees of the graph in log or uniform style\n"
            "\n"
            "--distribution\n"
            "    print the edge distribution each level or not\n"
            "\n"
            "--workset\n"
            "    display the workset or not\n"
            "\n"
            "--metrics\n"
            "    display the metrics or not\n"
            "\n"
            "--warp_map\n"
            "    warp mapping or thread mapping strategy\n"
            "\n"
            "--instrument\n"
            "    instrument the result in each level\n"
            "\n"
            "--source=<source node ID>|random\n"
            "    which node to start from\n"
            "\n"
            "--slots=<number of slots>\n"
            "--block_size=<block size>\n"
            "--group_size=<group size>\n"
            "\n");
}


void check_open(FILE *fp, char *filename) {
    if (!fp) {
        fprintf(stderr, "cannot open file: %s\n", filename);
        exit(1);
    }
}


int main(int argc, char **argv) {
    

    typedef int VertexId;
    typedef int SizeT;
    typedef int Value;


    /*********************************************************************
     * Commandline parsing
     *********************************************************************/
    util::CommandLineArgs args(argc, argv);
    // 0: prog   1: graph    2: bfs_type
    if ((argc < 3) || args.CheckCmdLineFlag("help")) {
        usage();
        return 1;
    }

    std::string graph = argv[1];
    std::string bfs_type = argv[2];


    printf("================================================================\n");
    printf("Graph:\t\t%s\n", graph.c_str());

    bool display_stat = args.CheckCmdLineFlag("stat");
    printf("Display statistics?\t\t%s\n", (display_stat ? "Yes" : "No"));


    bool display_distribution = args.CheckCmdLineFlag("distribution");
    printf("Display distribution?\t\t%s\n", (display_distribution ? "Yes" : "No"));

    bool display_workset = args.CheckCmdLineFlag("workset");
    printf("Display workset?\t\t%s\n", (display_workset ? "Yes" : "No"));

    bool display_metrics = args.CheckCmdLineFlag("metrics");
    printf("Display metrics?\t\t%s\n", (display_metrics ? "Yes" : "No"));

    bool warp_mapped = args.CheckCmdLineFlag("warp_map");
    printf("Warp mapping?\t\t%s\n", (warp_mapped ? "Yes" : "No"));

    bool instrument = args.CheckCmdLineFlag("instrument");
    printf("Instrument?\t\t%s\n", (instrument ? "Yes" : "No"));

    bool unordered = args.CheckCmdLineFlag("unordered");
    printf("Unordered?\t\t%s\n", (unordered ? "Yes" : "No"));

    VertexId source = 0;
    std::string src_str;
    bool randomized_source = false;
    args.GetCmdLineArgument("source", src_str);
    if (src_str.compare("random") == 0) {
        randomized_source = true;
        printf("Source node:\trandomized\n");
    } else {
        args.GetCmdLineArgument("source", source);
        printf("Source node:\t%d\n", source);
    }

    int slots = 0;
    args.GetCmdLineArgument("slots", slots);
    printf("Slot number:\t%d\n", slots);

    int block_size = 256;
    args.GetCmdLineArgument("block_size", block_size);
    printf("BLock size(threads):\t%d\n", block_size);

    int group_size = 32;
    args.GetCmdLineArgument("group_size", group_size);
    printf("Group size(threads):\t%d\n", group_size);


    graph::CsrGraph<VertexId, SizeT, Value> ga;


    /*********************************************************************
     * Build the graph from a file
     *********************************************************************/
    FILE *fp;

    if (graph == "tiny") {
        fp = fopen(getenv("TINY_GRAPH"), "r");
        check_open(fp, "tiny");
        if (graph::gen::myGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "fla") {
        fp = fopen(getenv("FLA_GRAPH"), "r");
        check_open(fp, "fla");
        if (graph::gen::myGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "mesh") {
    
        fp = fopen(getenv("MESH_GRAPH"), "r");
        check_open(fp, "mesh");
        if (graph::gen::myGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "rmat1") {
    
        fp = fopen(getenv("RMAT1_GRAPH"), "r");
        check_open(fp, "rmat1");
        if (graph::gen::myGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "rmat2") {
    
        fp = fopen(getenv("RMAT2_GRAPH"), "r");
        check_open(fp, "rmat2");
        if (graph::gen::cooGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "random1") {
    
        fp = fopen(getenv("RANDOM1_GRAPH"), "r");
        check_open(fp, "random1");
        if (graph::gen::cooGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "random2") {
    
        fp = fopen(getenv("RANDOM2_GRAPH"), "r");
        check_open(fp, "random2");
        if (graph::gen::cooGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "kkt") {

        fp = fopen(getenv("KKT_GRAPH"), "r");
        check_open(fp, "kkt");
        if (graph::gen::dimacsGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "copaper") {

        fp = fopen(getenv("COPAPER_GRAPH"), "r");
        check_open(fp, "copaper");
        if (graph::gen::dimacsGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "audi") {

        fp = fopen(getenv("AUDI_GRAPH"), "r");
        check_open(fp, "audi");
        if (graph::gen::dimacsGraphGen<VertexId, SizeT, Value>(fp, ga) !=0 ) return 1;

    } else if (graph == "amazon") {

        fp = fopen(getenv("AMAZON_GRAPH"), "r");
        check_open(fp, "amazon");
        if (graph::gen::cooGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;
    
    } else if (graph == "thermal") {

        fp = fopen(getenv("THERMAL_GRAPH"), "r");
        check_open(fp, "thermal");
        if (graph::gen::dimacsGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "eco") {

        fp = fopen(getenv("ECO_GRAPH"), "r");
        check_open(fp, "eco");
        if (graph::gen::dimacsGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else if (graph == "livejournal") {

        fp = fopen(getenv("LIVE_GRAPH"), "r");
        check_open(fp, "livejournal");
        if (graph::gen::cooGraphGen<VertexId, SizeT, Value>(fp, ga) != 0) return 1;

    } else {
        fprintf(stderr, "no graph is specified\n");
        return 1;
    }

    /*********************************************************************
     * Display
     *********************************************************************/

    util::Stats<VertexId, SizeT, Value> stats;
    stats.gen(ga);
    if (display_stat) stats.display();
		
    if (display_distribution) 
        bfs::BFSGraph_serial<VertexId, SizeT, Value>(
            ga,
            (VertexId) 0, 
            instrument, 
            display_distribution,
            display_workset);

    if (display_metrics) util::displayUtilizingEfficiency(ga);


    /*********************************************************************
     * Decide which node to start from
     *********************************************************************/

    if (randomized_source)
        source = util::randomNode(ga.n);
    else
        source = source % ga.n;

    printf("Traversing from %d\n", source);    


    /*********************************************************************
     * Traversing
     *********************************************************************/
    if (bfs_type == "serial") {

        bfs::BFSGraph_serial<VertexId, SizeT, Value>(
            ga, 
            source,
            instrument,
            display_distribution,
            display_workset);

    } else if (bfs_type == "bitmask") {

        bfs::BFSGraph_gpu_bitmask<VertexId, SizeT, Value>(
            ga,
            source,
            instrument);

    } else if (bfs_type == "queue") {

        bfs::BFSGraph_gpu_queue<VertexId, SizeT, Value>(
            ga,                                            
            source,
            instrument,
            block_size,
            warp_mapped,
            group_size,
            unordered,
            display_workset);

    } else if (bfs_type == "hash") {

        bfs::BFSGraph_gpu_hash<VertexId, SizeT, Value>(
            ga,
            source, 
            slots, 
            instrument);

    } else if (bfs_type == "topo") {

        bfs::BFSGraph_gpu_topo<VertexId, SizeT, Value>(
            ga,
            source, 
            stats,
            instrument);

    } else {
        fprintf(stderr, "no traverse type is specified. exit quietly\n");
    }


    fclose(fp);
    ga.del();
    return 0;
}
/*
 * Copyright (c) 2018, NVIDIA CORPORATION.  All rights reserved.
 *
 * NVIDIA CORPORATION and its licensors retain all intellectual property
 * and proprietary rights in and to this software, related documentation
 * and any modifications thereto.  Any use, reproduction, disclosure or
 * distribution of this software and related documentation without an express
 * license agreement from NVIDIA CORPORATION is strictly prohibited.
 *
 */

// Pagerank solver tests
// Author: Alex Fender afender@nvidia.com

#include "gtest/gtest.h"
#include "high_res_clock.h"
#include "cuda_profiler_api.h"
#include <cugraph.h>
#include "test_utils.h"
//#include "functions.h"
// do the perf measurements
// enabled by command line parameter s'--perf'
static int PERF = 0;

// iterations for perf tests
// enabled by command line parameter '--perf-iters"
static int PERF_MULTIPLIER = 5;

void dumy(void* in, void* out ) {

}

typedef struct Pagerank_Usecase_t {
  std::string matrix_file;
  std::string result_file;
  Pagerank_Usecase_t(const std::string& a, const std::string& b) : matrix_file(a), result_file(b){};
  Pagerank_Usecase_t& operator=(const Pagerank_Usecase_t& rhs) {
    matrix_file = rhs.matrix_file;
    result_file = rhs.result_file;
    return *this;
  }
} Pagerank_Usecase;

class Tests_Pagerank : public ::testing::TestWithParam<Pagerank_Usecase> {
  public:
  Tests_Pagerank() {  }
  static void SetupTestCase() {  }
  static void TearDownTestCase() { 
    if (PERF) {
     for (unsigned int i = 0; i < pagerank_time.size(); ++i) {
      std::cout <<  pagerank_time[i]/PERF_MULTIPLIER << std::endl;
     }
    } 
  }
  virtual void SetUp() {  }
  virtual void TearDown() {  }

  static std::vector<double> pagerank_time;   


  template <typename T, bool manual_tanspose>
  void run_current_test(const Pagerank_Usecase& param) {
     const ::testing::TestInfo* const test_info =::testing::UnitTest::GetInstance()->current_test_info();
     std::stringstream ss; 
     std::string test_id = std::string(test_info->test_case_name()) + std::string(".") + std::string(test_info->name()) + std::string("_") + getFileName(param.matrix_file)+ std::string("_") + ss.str().c_str();

     int m, k, nnz;
     MM_typecode mc;
     
     gdf_graph_ptr G{new gdf_graph, gdf_graph_deleter};
     gdf_column_ptr col_src, col_dest, col_pagerank;
     gdf_error status;
     float alpha = 0.85;
     float tol = 1E-5f;
     int max_iter = 500;
     bool has_guess = false;

     HighResClock hr_clock;
     double time_tmp;

     FILE* fpin = fopen(param.matrix_file.c_str(),"r");
     
     ASSERT_EQ(mm_properties<int>(fpin, 1, &mc, &m, &k, &nnz),0) << "could not read Matrix Market file properties"<< "\n";
     ASSERT_TRUE(mm_is_matrix(mc));
     ASSERT_TRUE(mm_is_coordinate(mc));
     ASSERT_FALSE(mm_is_complex(mc));
     ASSERT_FALSE(mm_is_skew(mc));
     
     // Allocate memory on host
     std::vector<int> cooRowInd(nnz), cooColInd(nnz);
     std::vector<T> cooVal(nnz), pagerank(m);

     // Read
     ASSERT_EQ( (mm_to_coo<int,T>(fpin, 1, nnz, &cooRowInd[0], &cooColInd[0], &cooVal[0], NULL)) , 0)<< "could not read matrix data"<< "\n";
     ASSERT_EQ(fclose(fpin),0);

     //std::cout<< *std::min_element(cooRowInd.begin(), cooRowInd.end()) <<std::endl;
     //std::cout<< *std::max_element(cooRowInd.begin(), cooRowInd.end()) <<std::endl <<std::endl;
     //std::cout<< *std::min_element(cooColInd.begin(), cooColInd.end()) <<std::endl;
     //std::cout<< *std::max_element(cooColInd.begin(), cooColInd.end()) <<std::endl <<std::endl; 
     //std::cout<< cooColInd.size() <<std::endl;
    
    // gdf columns
    col_src = create_gdf_column(cooRowInd);
    col_dest = create_gdf_column(cooColInd);
    col_pagerank = create_gdf_column(pagerank);

    ASSERT_EQ(gdf_edge_list_view(G.get(), col_src.get(), col_dest.get(), nullptr),0);
    if (manual_tanspose)
      ASSERT_EQ(gdf_add_transposed_adj_list(G.get()),0);

    cudaDeviceSynchronize();
    if (PERF) {
      hr_clock.start();
      for (int i = 0; i < PERF_MULTIPLIER; ++i) {
       status = gdf_pagerank(G.get(), col_pagerank.get(), alpha, tol, max_iter, has_guess);
       cudaDeviceSynchronize();
      }
      hr_clock.stop(&time_tmp);
      pagerank_time.push_back(time_tmp);
    }
    else {
      cudaProfilerStart();
      status = gdf_pagerank(G.get(), col_pagerank.get(), alpha, tol, max_iter, has_guess);
      cudaProfilerStop();
      cudaDeviceSynchronize();
    }
    EXPECT_EQ(status,0);

    // Check vs golden data
    if (param.result_file.length()>0)
    {
      std::vector<T> calculated_res(m);

      CUDA_RT_CALL(cudaMemcpy(&calculated_res[0],   col_pagerank.get()->data,   sizeof(T) * m, cudaMemcpyDeviceToHost));
      std::sort(calculated_res.begin(), calculated_res.end());
      fpin = fopen(param.result_file.c_str(),"rb");
      ASSERT_TRUE(fpin != NULL) << " Cannot read file with reference data: " << param.result_file << std::endl;
      std::vector<T> expected_res(m);
      ASSERT_EQ(read_binary_vector(fpin, m, expected_res), 0);
      fclose(fpin);
      T err;
      int n_err = 0;
      for (int i = 0; i < m; i++)
      {
          //if(i > (m-10))
          //  std::cout << expected_res[i] << " " << calculated_res[i] <<std::endl;
          err = fabs(expected_res[i] - calculated_res[i]);
          if (err> tol*1.1)
          {
              n_err++;
          }
      }
      if (n_err)
      {
          //EXPECT_NEAR(tot_err/n_err, cugraph_Const<T>::tol, cugraph_Const<T>::tol*9.99); // Network x used n*1e-10 for precision
          EXPECT_LE(n_err, 0.001*m); // we tolerate 0.1% of values with a litte difference
          //printf("number of incorrect entries: %d\n", n_err);
          //if (n_err > 0.001*m)
          //{
          //  eq(calculated_res,expected_res);
          //}
      }
    }
  }
};
 
std::vector<double> Tests_Pagerank::pagerank_time;

TEST_P(Tests_Pagerank, CheckFP32_manualT) {
    run_current_test<float, true>(GetParam());
}

TEST_P(Tests_Pagerank, CheckFP32) {
    run_current_test<float, false>(GetParam());
}

TEST_P(Tests_Pagerank, CheckFP64_manualT) {
    run_current_test<double,true>(GetParam());
}

TEST_P(Tests_Pagerank, CheckFP64) {
    run_current_test<double,false>(GetParam());
}

// --gtest_filter=*simple_test*
INSTANTIATE_TEST_CASE_P(simple_test, Tests_Pagerank, 
                        ::testing::Values(  Pagerank_Usecase("/datasets/networks/karate.mtx", "")
                                            ,Pagerank_Usecase("/datasets/golden_data/graphs/cit-Patents.mtx", "/datasets/golden_data/results/pagerank/cit-Patents.pagerank_val_0.85.bin")
                                            ,Pagerank_Usecase("/datasets/golden_data/graphs/ljournal-2008.mtx", "/datasets/golden_data/results/pagerank/ljournal-2008.pagerank_val_0.85.bin")
                                            ,Pagerank_Usecase("/datasets/golden_data/graphs/webbase-1M.mtx", "/datasets/golden_data/results/pagerank/webbase-1M.pagerank_val_0.85.bin")
                                            ,Pagerank_Usecase("/datasets/golden_data/graphs/web-BerkStan.mtx", "/datasets/golden_data/results/pagerank/web-BerkStan.pagerank_val_0.85.bin")
                                            ,Pagerank_Usecase("/datasets/golden_data/graphs/web-Google.mtx", "/datasets/golden_data/results/pagerank/web-Google.pagerank_val_0.85.bin")
                                            ,Pagerank_Usecase("/datasets/golden_data/graphs/wiki-Talk.mtx", "/datasets/golden_data/results/pagerank/wiki-Talk.pagerank_val_0.85.bin")
                                            //,Pagerank_Usecase("/datasets/bb_lt250m_4.mtx", "")
                                            //,Pagerank_Usecase("/datasets/bb_lt250m_3.mtx", "")
                                            //,Pagerank_Usecase("/datasets/caidaRouterLevel.mtx", "")
                                            //,Pagerank_Usecase("/datasets/citationCiteseer.mtx", "")
                                            //,Pagerank_Usecase("/datasets/coPapersDBLP.mtx", "")
                                            //,Pagerank_Usecase("/datasets/coPapersCiteseer.mtx", "")
                                            //,Pagerank_Usecase("/datasets/as-Skitter.mtx", "")
                                            //,Pagerank_Usecase("/datasets/hollywood.mtx", "")
                                            //,Pagerank_Usecase("/datasets/europe_osm.mtx", "")
                                            //,Pagerank_Usecase("/datasets/soc-LiveJournal1.mtx", "")
                                            //,Pagerank_Usecase("/datasets/twitter.mtx", "")
                                         )
                       );


int main(int argc, char **argv)  {
    srand(42);
    ::testing::InitGoogleTest(&argc, argv);
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--perf") == 0)
            PERF = 1;
        if (strcmp(argv[i], "--perf-iters") == 0)
            PERF_MULTIPLIER = atoi(argv[i+1]);
    }
        
  return RUN_ALL_TESTS();
}



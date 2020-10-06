/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governin_from_mtxg permissions and
 * limitations under the License.
 */

#include <utilities/base_fixture.hpp>
#include <utilities/test_utilities.hpp>

#include <algorithms.hpp>
#include <experimental/graph.hpp>
#include <experimental/graph_view.hpp>

#include <raft/cudart_utils.h>
#include <raft/handle.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/mr/device/cuda_memory_resource.hpp>

#include <gtest/gtest.h>

#include <algorithm>
#include <iterator>
#include <limits>
#include <numeric>
#include <vector>

template <typename vertex_t, typename edge_t, typename weight_t, typename result_t>
void pagerank_reference(edge_t* offsets,
                        vertex_t* indices,
                        weight_t* weights,
                        vertex_t* personalization_vertices,
                        result_t* personalization_values,
                        result_t* pageranks,
                        vertex_t num_vertices,
                        vertex_t personalization_vector_size,
                        result_t alpha,
                        result_t epsilon,
                        size_t max_iterations,
                        bool has_initial_guess)
{
  if (num_vertices == 0) { return; }

  if (has_initial_guess) {
    auto sum = std::accumulate(pageranks, pageranks + num_vertices, result_t{0.0});
    ASSERT_TRUE(sum > 0.0);
    std::for_each(pageranks, pageranks + num_vertices, [sum](auto& val) { val /= sum; });
  } else {
    std::for_each(pageranks, pageranks + num_vertices, [num_vertices](auto& val) {
      val = result_t{1.0} / static_cast<result_t>(num_vertices);
    });
  }

  if (personalization_vertices != nullptr) {
    auto sum = std::accumulate(
      personalization_values, personalization_values + personalization_vector_size, result_t{0.0});
    ASSERT_TRUE(sum > 0.0);
    std::for_each(personalization_values,
                  personalization_values + personalization_vector_size,
                  [sum](auto& val) { val /= sum; });
  }

  std::vector<weight_t> out_weight_sums(num_vertices, result_t{0.0});
  for (vertex_t i = 0; i < num_vertices; ++i) {
    for (auto j = *(offsets + i); j < *(offsets + i + 1); ++j) {
      auto nbr = indices[j];
      auto w   = weights != nullptr ? weights[j] : 1.0;
      out_weight_sums[nbr] += w;
    }
  }

  std::vector<result_t> old_pageranks(num_vertices, result_t{0.0});
  size_t iter{0};
  while (true) {
    std::copy(pageranks, pageranks + num_vertices, old_pageranks.begin());
    result_t dangling_sum{0.0};
    for (vertex_t i = 0; i < num_vertices; ++i) {
      if (out_weight_sums[i] == result_t{0.0}) { dangling_sum += old_pageranks[i]; }
    }
    for (vertex_t i = 0; i < num_vertices; ++i) {
      pageranks[i] = result_t{0.0};
      for (auto j = *(offsets + i); j < *(offsets + i + 1); ++j) {
        auto nbr = indices[j];
        auto w   = weights != nullptr ? weights[j] : result_t{1.0};
        pageranks[i] += alpha * old_pageranks[nbr] * (w / out_weight_sums[nbr]);
      }
      if (personalization_vertices == nullptr) {
        pageranks[i] += (dangling_sum + (1.0 - alpha)) / static_cast<result_t>(num_vertices);
      }
    }
    if (personalization_vertices != nullptr) {
      for (vertex_t i = 0; i < personalization_vector_size; ++i) {
        auto v = personalization_vertices[i];
        pageranks[v] += (dangling_sum + (1.0 - alpha)) * personalization_values[i];
      }
    }
    result_t diff_sum{0.0};
    for (vertex_t i = 0; i < num_vertices; ++i) {
      diff_sum += fabs(pageranks[i] - old_pageranks[i]);
    }
    if (diff_sum < static_cast<result_t>(num_vertices) * epsilon) { break; }
    iter++;
    ASSERT_TRUE(iter < max_iterations);
  }

  return;
}

typedef struct PageRank_Usecase_t {
  std::string graph_file_full_path{};
  bool test_weighted{false};

  PageRank_Usecase_t(std::string const& graph_file_path, bool test_weighted)
    : test_weighted(test_weighted)
  {
    if ((graph_file_path.length() > 0) && (graph_file_path[0] != '/')) {
      graph_file_full_path = cugraph::test::get_rapids_dataset_root_dir() + "/" + graph_file_path;
    } else {
      graph_file_full_path = graph_file_path;
    }
  };
} PageRank_Usecase;

class Tests_PageRank : public ::testing::TestWithParam<PageRank_Usecase> {
 public:
  Tests_PageRank() {}
  static void SetupTestCase() {}
  static void TearDownTestCase() {}

  virtual void SetUp() {}
  virtual void TearDown() {}

  template <typename vertex_t, typename edge_t, typename weight_t, typename result_t>
  void run_current_test(PageRank_Usecase const& configuration)
  {
    raft::handle_t handle{};

    auto graph =
      cugraph::test::read_graph_from_matrix_market_file<vertex_t, edge_t, weight_t, true>(
        handle, configuration.graph_file_full_path, configuration.test_weighted);
    auto graph_view = graph.view();

    std::vector<edge_t> h_offsets(graph_view.get_number_of_vertices() + 1);
    std::vector<vertex_t> h_indices(graph_view.get_number_of_edges());
    std::vector<weight_t> h_weights{};
    raft::update_host(h_offsets.data(),
                      graph_view.offsets(),
                      graph_view.get_number_of_vertices() + 1,
                      handle.get_stream());
    raft::update_host(h_indices.data(),
                      graph_view.indices(),
                      graph_view.get_number_of_edges(),
                      handle.get_stream());
    if (graph_view.is_weighted()) {
      h_weights.assign(graph_view.get_number_of_edges(), weight_t{0.0});
      raft::update_host(h_weights.data(),
                        graph_view.weights(),
                        graph_view.get_number_of_edges(),
                        handle.get_stream());
    }
    CUDA_TRY(cudaStreamSynchronize(handle.get_stream()));

    std::vector<result_t> h_reference_pageranks(graph_view.get_number_of_vertices());

    result_t constexpr alpha{0.85};
    result_t constexpr epsilon{1e-6};

    pagerank_reference(h_offsets.data(),
                       h_indices.data(),
                       h_weights.size() > 0 ? h_weights.data() : static_cast<weight_t*>(nullptr),
                       static_cast<vertex_t*>(nullptr),
                       static_cast<result_t*>(nullptr),
                       h_reference_pageranks.data(),
                       graph_view.get_number_of_vertices(),
                       vertex_t{0},
                       alpha,
                       epsilon,
                       std::numeric_limits<size_t>::max(),
                       false);

    rmm::device_uvector<result_t> d_pageranks(graph_view.get_number_of_vertices(),
                                              handle.get_stream());

    CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement

    cugraph::experimental::pagerank(handle,
                                    graph_view,
                                    static_cast<weight_t*>(nullptr),
                                    static_cast<vertex_t*>(nullptr),
                                    static_cast<result_t*>(nullptr),
                                    vertex_t{0},
                                    d_pageranks.begin(),
                                    alpha,
                                    epsilon,
                                    std::numeric_limits<size_t>::max(),
                                    false,
                                    false);

    CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement

    std::vector<result_t> h_cugraph_pageranks(graph_view.get_number_of_vertices());

    raft::update_host(
      h_cugraph_pageranks.data(), d_pageranks.data(), d_pageranks.size(), handle.get_stream());
    CUDA_TRY(cudaStreamSynchronize(handle.get_stream()));

    auto nearly_equal = [epsilon](auto lhs, auto rhs) { return std::fabs(lhs - rhs) < epsilon; };

    ASSERT_TRUE(std::equal(h_reference_pageranks.begin(),
                           h_reference_pageranks.end(),
                           h_cugraph_pageranks.begin(),
                           nearly_equal))
      << "PageRank values do not match with the reference values.";
  }
};

// FIXME: add tests for type combinations
TEST_P(Tests_PageRank, CheckInt32Int32FloatFloat)
{
  run_current_test<int32_t, int32_t, float, float>(GetParam());
}

INSTANTIATE_TEST_CASE_P(simple_test,
                        Tests_PageRank,
                        ::testing::Values(PageRank_Usecase("test/datasets/karate.mtx", false),
                                          PageRank_Usecase("test/datasets/karate.mtx", true),
                                          PageRank_Usecase("test/datasets/web-Google.mtx", false),
                                          PageRank_Usecase("test/datasets/web-Google.mtx", true),
                                          PageRank_Usecase("test/datasets/ljournal-2008.mtx",
                                                           false),
                                          PageRank_Usecase("test/datasets/ljournal-2008.mtx", true),
                                          PageRank_Usecase("test/datasets/webbase-1M.mtx", false),
                                          PageRank_Usecase("test/datasets/webbase-1M.mtx", true)));

CUGRAPH_TEST_PROGRAM_MAIN()

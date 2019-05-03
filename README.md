# <div align="left"><img src="img/rapids_logo.png" width="90px"/>&nbsp;cuGraph - GPU Graph Analytics</div>

[![Build Status](http://18.191.94.64/buildStatus/icon?job=cugraph-master)](http://18.191.94.64/job/cugraph-master/)  [![Documentation Status](https://readthedocs.org/projects/cugraph/badge/?version=latest)](https://docs.rapids.ai/api/cugraph/nightly/)

The [RAPIDS](https://rapids.ai) cuGraph library is a collection of graph analytics that process data found in GPU Dataframes - see [cuDF](https://github.com/rapidsai/cudf).  cuGraph aims to provide a NetworkX-like API that will be familiar to data scientists, so they can now build GPU-accelerated workflows more easily.

For example, the following snippet downloads a CSV file containing friendship information of students in a karate dojo, then uses the GPU to parse it into rows and columns and greate a graph. This graph is then used to run cugraph's pagerank algorithm to find the student/students who are the most popular.
```python
import cugraph, cudf, requests
from collections import OrderedDict
from io import StringIO

# read the data into a cuDF DataFrame
url = "https://raw.githubusercontent.com/rapidsai/cugraph/branch-0.7/datasets/karate.csv"
content = requests.get(url).content.decode('utf-8')
gdf = cudf.read_csv(StringIO(content), names=["subject", "friend"],
                    delimiter=' ', dtype=['int32', 'int32'])

# create graph with nodes being unique students and edges representing friendship
G = cugraph.Graph()
G.add_edge_list(gdf["subject"], gdf["friend"])
# apply the pagerank algorithm to the graph
results = cugraph.pagerank(G)

# Find the most connected student(s) using the scores from the pagerank algorithm:
max_score = results['pagerank'].max()
popular_subject = [i for i in range(len(results))
                   if results['pagerank'][i] == max_score]
print("Most connected student(s): " + str(popular_subject) + " have a score of: " + str(max_score))
```

Output:
```
Most connected student(s): [33] have a score of: 0.10091735
```

For additional examples, browse our complete [API documentation](https://docs.rapids.ai/api/cugraph/stable/), or check out our more detailed [notebooks](https://github.com/rapidsai/notebooks-extended).

**NOTE:** For the latest stable [README.md](https://github.com/rapidsai/cudf/blob/master/README.md) ensure you are on the `master` branch.

## Getting cuGraph

### Intro
There are 4 ways to get cuGraph :
1. [Quick start with Docker Demo Repo](#quick)
1. [Conda Installation](#conda)
1. [Build from Source](#source)

<a name="quick"></a>

## Quick Start  

Please see the [Demo Docker Repository](https://hub.docker.com/r/rapidsai/rapidsai/), choosing a tag based on the NVIDIA CUDA version you’re running. This provides a ready to run Docker container with example notebooks and data, showcasing how you can utilize all of the RAPIDS libraries: cuDF, cuML, and cuGraph.

<a name="conda"></a>

### Conda

It is easy to install cuGraph using conda. You can get a minimal conda installation with [Miniconda](https://conda.io/miniconda.html) or get the full installation with [Anaconda](https://www.anaconda.com/download).

Install and update cuGraph using the conda command:

```bash
# CUDA 9.2
conda install -c nvidia -c rapidsai -c numba -c conda-forge -c defaults cugraph

# CUDA 10.0
conda install -c nvidia/label/cuda10.0 -c rapidsai/label/cuda10.0 -c numba -c conda-forge -c defaults cugraph
```

Note: This conda installation only applies to Linux and Python versions 3.6/3.7.

<a name="source"></a>

------

## <div align="left"><img src="img/rapids_logo.png" width="265px"/></div> Open GPU Data Science

The RAPIDS suite of open source software libraries aim to enable execution of end-to-end data science and analytics pipelines entirely on GPUs. It relies on NVIDIA® CUDA® primitives for low-level compute optimization, but exposing that GPU parallelism and high-bandwidth memory speed through user-friendly Python interfaces.

<p align="center"><img src="img/rapids_arrow.png" width="80%"/></p>

### Apache Arrow on GPU

The GPU version of [Apache Arrow](https://arrow.apache.org/) is a common API that enables efficient interchange of tabular data between processes running on the GPU. End-to-end computation on the GPU avoids unnecessary copying and converting of data off the GPU, reducing compute time and cost for high-performance analytics common in artificial intelligence workloads. As the name implies, cuDF uses the Apache Arrow columnar data format on the GPU. Currently, a subset of the features in Apache Arrow are supported.


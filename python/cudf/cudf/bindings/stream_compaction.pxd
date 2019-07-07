# Copyright (c) 2019, NVIDIA CORPORATION.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

from cudf.bindings.cudf_cpp cimport *

from libcpp.vector cimport vector

cdef extern from "stream_compaction.hpp" namespace "cudf" nogil:

    #defined in cpp/include/stream_compaction.hpp
    ctypedef enum duplicate_keep_option:
        KEEP_FIRST
        KEEP_LAST
        KEEP_NONE

    #defined in cpp/include/stream_compaction.hpp
    ctypedef enum any_or_all:
        ANY
        ALL

    cdef gdf_column apply_boolean_mask(const gdf_column &input,
                                       const gdf_column &boolean_mask) except +

    cdef cudf_table apply_boolean_mask(const cudf_table &input,
                                       const gdf_column &boolean_mask) except +

    cdef gdf_column drop_nulls(const gdf_column &input) except +

    cdef cudf_table drop_nulls(const cudf_table &input,
                               const vector[gdf_index_type]& column_indices,
                               const any_or_all drop_if) except +

    cdef cudf_table drop_duplicates(const cudf_table& input_table,
                                    const cudf_table& key_columns,
                                    const duplicate_keep_option keep) except +


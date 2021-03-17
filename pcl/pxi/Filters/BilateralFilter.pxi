# -*- coding: utf-8 -*-
cimport pcl_defs as cpp
cimport pcl_filters as pcl_fil

cdef class BilateralFilter:
    """
    Filter class uses point neighborhood statistics to filter noisy data and smooth it.
    """
    cdef pcl_fil.BilateralFilter_t *me

    def __cinit__(self, PointCloud pc not None):
        self.me = new pcl_fil.BilateralFilter_t()
        (<cpp.PCLBase_t*>self.me).setInputCloud (pc.thisptr_shared)

    def __dealloc__(self):
        del self.me
'''
    property sigma_s:
        def __get__(self):
            return self.me.getSigmaS()
        def __set__(self, int k):
            self.me.setSigmaS()

    property sigma_r:
        def __get__(self):
            return self.me.getSigmaR()
        def __set__(self, int k):
            self.me.setSigmaR()
'''
    property HalfSize:
        def __get__(self):
            return (<pcl_fil.FilterIndices[cpp.PointXYZ]*>self.me).getHalfSize()
        def __set__(self, bool sigma_s):
            (<pcl_fil.FilterIndices[cpp.PointXYZ]*>self.me).setHalfSize(sigma_s)

    property StdDev:
        def __get__(self):
            return self.me.getStdDev()
        def __set__(self, double sigma_r):
            self.me.setStdDev(sigma_r) 

    def set_half_size(self, double sigma_s):
        """
        Set the number of points (k) to use for mean distance estimation. 
        """
        self.me.setHalfSize(sigma_s)

    def set_std_dev(self, double sigma_r):
        """
        Set the standard deviation multiplier threshold.
        """
        self.me.setStdDev(sigma_r)

    def compute_point_weight(self, int pid, vector[int] &indices, vector[float] &distances):
        """
        Compute the intensity average for a single point.
        """
        self.me.computePointWeight(pid, indices, distances)

    def filter(self):
        """
        Apply the filter according to the previously set parameters and return
        a new pointcloud
        """
        cdef PointCloud pc = PointCloud()
        self.me.applyfilter(pc.thisptr()[0])
        return pc


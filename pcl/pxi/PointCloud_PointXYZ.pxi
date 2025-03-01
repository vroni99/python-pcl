# -*- coding: utf-8 -*-
cimport pcl_defs as cpp
import numpy as np
cimport numpy as cnp

cnp.import_array()

# parts
cimport pcl_common as pcl_cmn
cimport pcl_features as pcl_ftr
cimport pcl_filters as pcl_fil
cimport pcl_io as pcl_io
cimport pcl_kdtree as pcl_kdt
cimport pcl_octree as pcl_oct
cimport pcl_sample_consensus as pcl_sac
# cimport pcl_search as pcl_sch
cimport pcl_segmentation as pcl_seg
cimport pcl_surface as pcl_srf
cimport pcl_range_image as pcl_rim
cimport pcl_registration_160 as pcl_reg

from libcpp cimport bool
cimport indexing as idx

from boost_shared_ptr cimport sp_assign

cdef extern from "minipcl.h":
    void mpcl_compute_normals(cpp.PointCloud_t, int ksearch,
                              double searchRadius,
                              cpp.PointCloud_Normal_t) except +
    void mpcl_extract(cpp.PointCloudPtr_t, cpp.PointCloud_t *,
                              cpp.PointIndices_t *, bool) except +
    ## void mpcl_extract_HarrisKeypoint3D(cpp.PointCloudPtr_t, cpp.PointCloud_PointXYZ *) except +
    # void mpcl_extract_HarrisKeypoint3D(cpp.PointCloudPtr_t, cpp.PointCloud_t *) except +


cdef extern from "ProjectInliers.h":
    void mpcl_ProjectInliers_setModelCoefficients(pcl_fil.ProjectInliers_t) except +

# Empirically determine strides, for buffer support.
# XXX Is there a more elegant way to get these?
cdef Py_ssize_t _strides[2]
cdef PointCloud _pc_tmp = PointCloud(np.array([[1, 2, 3],
                                               [4, 5, 6]], dtype=np.float32))

cdef cpp.PointCloud[cpp.PointXYZ] *p = _pc_tmp.thisptr()
_strides[0] = (  <Py_ssize_t><void *>idx.getptr(p, 1)
               - <Py_ssize_t><void *>idx.getptr(p, 0))
_strides[1] = (  <Py_ssize_t><void *>&(idx.getptr(p, 0).y)
               - <Py_ssize_t><void *>&(idx.getptr(p, 0).x))
_pc_tmp = None

cdef class PointCloud:
    """Represents a cloud of points in 3-d space.

    A point cloud can be initialized from either a NumPy ndarray of shape
    (n_points, 3), from a list of triples, or from an integer n to create an
    "empty" cloud of n points.

    To load a point cloud from disk, use pcl.load.
    """
    def __cinit__(self, init=None):
        cdef PointCloud other
        
        self._view_count = 0
        
        # TODO: NG --> import pcl --> pyd Error(python shapedptr/C++ shard ptr collusion?)
        # sp_assign(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared, new cpp.PointCloud[cpp.PointXYZ]())
        sp_assign(self.thisptr_shared, new cpp.PointCloud[cpp.PointXYZ]())
        
        if init is None:
            return
        elif isinstance(init, (numbers.Integral, np.integer)):
            self.resize(init)
        elif isinstance(init, np.ndarray):
            self.from_array(init)
        elif isinstance(init, Sequence):
            self.from_list(init)
        elif isinstance(init, type(self)):
            other = init
            self.thisptr()[0] = other.thisptr()[0]
        else:
            raise TypeError("Can't initialize a PointCloud from a %s"
                            % type(init))

    property width:
        """ property containing the width of the point cloud """
        def __get__(self): return self.thisptr().width
    property height:
        """ property containing the height of the point cloud """
        def __get__(self): return self.thisptr().height
    property size:
        """ property containing the number of points in the point cloud """
        def __get__(self): return self.thisptr().size()
    property is_dense:
        """ property containing whether the cloud is dense or not """
        def __get__(self): return self.thisptr().is_dense

    def __repr__(self):
        return "<PointCloud of %d points>" % self.size

    # Buffer protocol support. Taking a view locks the pointcloud for
    # resizing, because that can move it around in memory.
    def __getbuffer__(self, Py_buffer *buffer, int flags):
        # TODO parse flags
        cdef Py_ssize_t npoints = self.thisptr().size()
        
        if self._view_count == 0:
            self._shape[0] = npoints
            self._shape[1] = 3
        self._view_count += 1

        buffer.buf = <char *>&(idx.getptr_at(self.thisptr(), 0).x)
        buffer.format = 'f'
        buffer.internal = NULL
        buffer.itemsize = sizeof(float)
        buffer.len = npoints * 3 * sizeof(float)
        buffer.ndim = 2
        buffer.obj = self
        buffer.readonly = 0
        buffer.shape = self._shape
        buffer.strides = _strides
        buffer.suboffsets = NULL

    def __releasebuffer__(self, Py_buffer *buffer):
        self._view_count -= 1

    # Pickle support. XXX this copies the entire pointcloud; it would be nice
    # to have an asarray member that returns a view, or even better, implement
    # the buffer protocol (https://docs.python.org/c-api/buffer.html).
    def __reduce__(self):
        return type(self), (self.to_array(),)

    property sensor_origin:
        def __get__(self):
            cdef cpp.Vector4f origin = self.thisptr().sensor_origin_
            cdef float *data = origin.data()
            return np.array([data[0], data[1], data[2], data[3]],
                            dtype=np.float32)

        def __set__(self, cnp.ndarray[cnp.float32_t, ndim=1] new_origin):
            self.thisptr().sensor_origin_ = cpp.Vector4f(
                    new_origin[0],
                    new_origin[1],
                    new_origin[2],
                    0.0)

    property sensor_orientation:
        def __get__(self):
            # NumPy doesn't have a quaternion type, so we return a 4-vector.
            cdef cpp.Quaternionf o = self.thisptr().sensor_orientation_
            return np.array([o.w(), o.x(), o.y(), o.z()], dtype=np.float32)
        
        def __set__(self, cnp.ndarray[cnp.float32_t, ndim=1] new_orient):
            self.thisptr().sensor_orientation_ = cpp.Quaternionf(
                    new_orient[0],
                    new_orient[1],
                    new_orient[2],
                    new_orient[3])

    @cython.boundscheck(False)
    def from_array(self, cnp.ndarray[cnp.float32_t, ndim=2] arr not None):
        """
        Fill this object from a 2D numpy array (float32)
        """
        assert arr.shape[1] == 3
        
        cdef cnp.npy_intp npts = arr.shape[0]
        self.resize(npts)
        self.thisptr().width = npts
        self.thisptr().height = 1
        
        cdef cpp.PointXYZ *p
        for i in range(npts):
            p = idx.getptr(self.thisptr(), i)
            p.x, p.y, p.z = arr[i, 0], arr[i, 1], arr[i, 2]

    @cython.boundscheck(False)
    def to_array(self):
        """
        Return this object as a 2D numpy array (float32)
        """
        cdef float x,y,z
        cdef cnp.npy_intp n = self.thisptr().size()
        cdef cnp.ndarray[cnp.float32_t, ndim=2, mode="c"] result
        cdef cpp.PointXYZ *p
        
        result = np.empty((n, 3), dtype=np.float32)
        for i in range(n):
            p = idx.getptr(self.thisptr(), i)
            result[i, 0] = p.x
            result[i, 1] = p.y
            result[i, 2] = p.z
        
        return result

    def from_list(self, _list):
        """
        Fill this pointcloud from a list of 3-tuples
        """
        cdef Py_ssize_t npts = len(_list)
        self.resize(npts)
        self.thisptr().width = npts
        self.thisptr().height = 1
        cdef cpp.PointXYZ* p
        # OK
        # p = idx.getptr(self.thisptr(), 1)
        # enumerate ? -> i -> type unknown
        for i, l in enumerate(_list):
             p = idx.getptr(self.thisptr(), <int> i)
             p.x, p.y, p.z = l

    def to_list(self):
        """
        Return this object as a list of 3-tuples
        """
        return self.to_array().tolist()

    def resize(self, cnp.npy_intp x):
        if self._view_count > 0:
            raise ValueError("can't resize PointCloud while there are"
                             " arrays/memoryviews referencing it")
        if x < 0:
            raise MemoryError("can't resize PointCloud to negative size")

        self.thisptr().resize(x)

    def get_point(self, cnp.npy_intp row, cnp.npy_intp col):
        """
        Return a point (3-tuple) at the given row/column
        """
        cdef cpp.PointXYZ *p = idx.getptr_at2 [cpp.PointXYZ](self.thisptr(), row, col)
        return p.x, p.y, p.z

    def __getitem__(self, cnp.npy_intp nmidx):
        cdef cpp.PointXYZ *p = idx.getptr_at(self.thisptr(), nmidx)
        return p.x, p.y, p.z

    def from_file(self, char *f):
        """
        Fill this pointcloud from a file (a local path).
        Only pcd files supported currently.
        
        Deprecated; use pcl.load instead.
        """
        return self._from_pcd_file(f)

    def _from_pcd_file(self, const char *s):
        cdef int ok = -1
        # with nogil:
        #     ok = pcl_io.loadPCDFile [cpp.PointXYZ](string(s), deref(self.thisptr()))
        # Cython 0.29? : Calling gil-requiring function not allowed without gil
        ok = pcl_io.loadPCDFile [cpp.PointXYZ](string(s), deref(self.thisptr()))
        return ok

    def _from_ply_file(self, const char *s):
        cdef int ok = -1
        # with nogil:
        #     ok = pcl_io.loadPLYFile [cpp.PointXYZ](string(s), deref(self.thisptr()))
        ok = pcl_io.loadPLYFile [cpp.PointXYZ](string(s), deref(self.thisptr()))
        return ok

    # no use pcl1.6
    def _from_obj_file(self, const char *s):
        cdef int ok = -1
        # with nogil:
        #     ok = pcl_io.loadOBJFile [cpp.PointXYZ](string(s), deref(self.thisptr()))
        return ok

    def to_file(self, const char *fname, bool ascii=True):
        """Save pointcloud to a file in PCD format.

        Deprecated: use pcl.save instead.
        """
        return self._to_pcd_file(fname, not ascii)

    def _to_pcd_file(self, const char *f, bool binary=False):
        cdef int ok = -1
        cdef string s = string(f)
        # with nogil:
        #     ok = pcl_io.savePCDFile [cpp.PointXYZ](s, deref(self.thisptr()), binary)
        ok = pcl_io.savePCDFile [cpp.PointXYZ](s, deref(self.thisptr()), binary)
        return ok

    def _to_ply_file(self, const char *f, bool binary=False):
        cdef int ok = -1
        cdef string s = string(f)
        # with nogil:
        #     ok = pcl_io.savePLYFile [cpp.PointXYZ](s, deref(self.thisptr()), binary)
        ok = pcl_io.savePLYFile [cpp.PointXYZ](s, deref(self.thisptr()), binary)
        return ok

    def make_segmenter(self):
        """
        Return a pcl.Segmentation object with this object set as the input-cloud
        """
        seg = Segmentation()
        cdef pcl_seg.SACSegmentation_t *cseg = <pcl_seg.SACSegmentation_t *>seg.me
        cseg.setInputCloud(self.thisptr_shared)
        return seg

    def make_segmenter_normals(self, int ksearch=-1, double searchRadius=-1.0):
        """
        Return a pcl.SegmentationNormal object with this object set as the input-cloud
        """
        cdef cpp.PointCloud_Normal_t normals
        mpcl_compute_normals(<cpp.PointCloud[cpp.PointXYZ]> deref(self.thisptr()), ksearch, searchRadius, normals)
        seg = SegmentationNormal()
        cdef pcl_seg.SACSegmentationFromNormals_t *cseg = <pcl_seg.SACSegmentationFromNormals_t *>seg.me
        cseg.setInputCloud(self.thisptr_shared)
        cseg.setInputNormals (normals.makeShared());
        return seg

    def make_statistical_outlier_filter(self):
        """
        Return a pcl.StatisticalOutlierRemovalFilter object with this object set as the input-cloud
        """
        # fil = StatisticalOutlierRemovalFilter()
        # cdef pcl_fil.StatisticalOutlierRemoval_t *cfil = <pcl_fil.StatisticalOutlierRemoval_t *>fil.me
        # cfil.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return StatisticalOutlierRemovalFilter(self)

    def make_voxel_grid_filter(self):
        """
        Return a pcl.VoxelGridFilter object with this object set as the input-cloud
        """
        fil = VoxelGridFilter()
        cdef pcl_fil.VoxelGrid_t *cfil = <pcl_fil.VoxelGrid_t *>fil.me
        cfil.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return fil
    
    def make_bilateral_filter(self):
        fil =  BilateralFilter()
        cdef pcl_fil.BilateralFilter_t *cfil = <pcl_fil.BilateralFilter_t *>fil.me
        cfil.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return fil 

    def make_ApproximateVoxelGrid(self):
        """
        Return a pcl.ApproximateVoxelGrid object with this object set as the input-cloud
        """
        fil = ApproximateVoxelGrid()
        cdef pcl_fil.ApproximateVoxelGrid_t *cfil = <pcl_fil.ApproximateVoxelGrid_t *>fil.me
        cfil.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return fil

    def make_passthrough_filter(self):
        """
        Return a pcl.PassThroughFilter object with this object set as the input-cloud
        """
        fil = PassThroughFilter()
        cdef pcl_fil.PassThrough_t *cfil = <pcl_fil.PassThrough_t *>fil.me
        cfil.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return fil

    def make_moving_least_squares(self):
        """
        Return a pcl.MovingLeastSquares object with this object as input cloud.
        """
        mls = MovingLeastSquares()
        cdef pcl_srf.MovingLeastSquares_t *cmls = <pcl_srf.MovingLeastSquares_t *>mls.me
        cmls.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return mls

    def make_kdtree(self):
        """
        Return a pcl.kdTree object with this object set as the input-cloud
        
        Deprecated: use the pcl.KdTree constructor on this cloud.
        """
        return KdTree(self)

    def make_kdtree_flann(self):
        """
        Return a pcl.kdTreeFLANN object with this object set as the input-cloud
        Deprecated: use the pcl.KdTreeFLANN constructor on this cloud.
        """
        return KdTreeFLANN(self)

    def make_octree(self, double resolution):
        """
        Return a pcl.octree object with this object set as the input-cloud
        """
        octree = OctreePointCloud(resolution)
        octree.set_input_cloud(self)
        return octree

    def make_octreeSearch(self, double resolution):
        """
        Return a pcl.make_octreeSearch object with this object set as the input-cloud
        """
        octreeSearch = OctreePointCloudSearch(resolution)
        octreeSearch.set_input_cloud(self)
        return octreeSearch

    # pcl 1.6.0 use ok
    # cpl 1.7.2, 1.8.0 use ng(octree_pointcloud_changedetector.h(->octree_pointcloud.h) include headerfile comment octree2buf_base.h)
    def make_octreeChangeDetector(self, double resolution):
        """
        Return a pcl.make_octreeSearch object with this object set as the input-cloud
        """
        octreeChangeDetector = OctreePointCloudChangeDetector(resolution)
        octreeChangeDetector.set_input_cloud(self)
        return octreeChangeDetector

    def make_crophull(self):
        """
        Return a pcl.CropHull object with this object set as the input-cloud

        Deprecated: use the pcl.Vertices constructor on this cloud.
        """
        return CropHull(self)

    def make_cropbox(self):
        """
        Return a pcl.CropBox object with this object set as the input-cloud
        Deprecated: use the pcl.Vertices constructor on this cloud.
        """
        return CropBox(self)

    def make_IntegralImageNormalEstimation(self):
        """
        Return a pcl.IntegralImageNormalEstimation object with this object set as the input-cloud
        Deprecated: use the pcl.Vertices constructor on this cloud.
        """
        return IntegralImageNormalEstimation(self)

    def extract(self, pyindices, bool negative=False):
        """
        Given a list of indices of points in the pointcloud, return a 
        new pointcloud containing only those points.
        """
        cdef PointCloud result
        cdef cpp.PointIndices_t *ind = new cpp.PointIndices_t()
        
        for i in pyindices:
            ind.indices.push_back(i)
        
        result = PointCloud()
        # result = ExtractIndices()
        # (<cpp.PointCloud[cpp.PointXYZ]> deref(self.thisptr())
        mpcl_extract(self.thisptr_shared, result.thisptr(), ind, negative)
        # XXX are we leaking memory here? del ind causes a double free...
        
        return result

    def make_ProjectInliers(self):
        """
        Return a pcl_fil.ProjectInliers object with this object set as the input-cloud
        """
        # proj = ProjectInliers()
        # cdef pcl_fil.ProjectInliers_t *cproj = <pcl_fil.ProjectInliers_t *>proj.me
        # cproj.setInputCloud(self.thisptr_shared)
        # return proj
        # # cdef pcl_fil.ProjectInliers_t* projInliers
        # # mpcl_ProjectInliers_setModelCoefficients(projInliers)
        # mpcl_ProjectInliers_setModelCoefficients(deref(projInliers))
        # # proj = ProjectInliers()
        # cdef pcl_fil.ProjectInliers_t *cproj = <pcl_fil.ProjectInliers_t *>projInliers
        # cproj.setInputCloud(self.thisptr_shared)
        # return proj
        # # NG
        # cdef pcl_fil.ProjectInliers_t* projInliers
        # # mpcl_ProjectInliers_setModelCoefficients(projInliers)
        # mpcl_ProjectInliers_setModelCoefficients(deref(projInliers))
        # projInliers.setInputCloud(self.thisptr_shared)
        # proj = ProjectInliers()
        # proj.me = projInliers
        # return proj
        proj = ProjectInliers()
        cdef pcl_fil.ProjectInliers_t *cproj = <pcl_fil.ProjectInliers_t *>proj.me
        # mpcl_ProjectInliers_setModelCoefficients(cproj)
        mpcl_ProjectInliers_setModelCoefficients(deref(cproj))
        cproj.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return proj

    def make_RadiusOutlierRemoval(self):
        """
        Return a pcl_fil.RadiusOutlierRemoval object with this object set as the input-cloud
        """
        fil = RadiusOutlierRemoval()
        cdef pcl_fil.RadiusOutlierRemoval_t *cfil = <pcl_fil.RadiusOutlierRemoval_t *>fil.me
        cfil.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return fil

    def make_ConditionAnd(self):
        """
        Return a pcl.ConditionAnd object with this object set as the input-cloud
        """
        condAnd = ConditionAnd()
        cdef pcl_fil.ConditionAnd_t *cCondAnd = <pcl_fil.ConditionAnd_t *>condAnd.me
        return condAnd

    def make_ConditionalRemoval(self, ConditionAnd range_conf):
        """
        Return a pcl.ConditionalRemoval object with this object set as the input-cloud
        """
        condRemoval = ConditionalRemoval(range_conf)
        cdef pcl_fil.ConditionalRemoval_t *cCondRemoval = <pcl_fil.ConditionalRemoval_t *>condRemoval.me
        cCondRemoval.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return condRemoval

    def make_ConcaveHull(self):
        """
        Return a pcl.ConditionalRemoval object with this object set as the input-cloud
        """
        concaveHull = ConcaveHull()
        cdef pcl_srf.ConcaveHull_t *cConcaveHull = <pcl_srf.ConcaveHull_t *>concaveHull.me
        cConcaveHull.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return concaveHull

    def make_HarrisKeypoint3D(self):
        """
        Return a pcl.PointCloud object with this object set as the input-cloud
        """
        harris = HarrisKeypoint3D(self)
        # harris = HarrisKeypoint3D()
        # cdef keypt.HarrisKeypoint3D_t *charris = <keypt.HarrisKeypoint3D_t *>harris.me
        # charris.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return harris

    def make_NormalEstimation(self):
        normalEstimation = NormalEstimation()
        cdef pcl_ftr.NormalEstimation_t *cNormalEstimation = <pcl_ftr.NormalEstimation_t *>normalEstimation.me
        cNormalEstimation.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return normalEstimation

    def make_VFHEstimation(self):
        vfhEstimation = VFHEstimation()
        cdef pcl_ftr.VFHEstimation_t *cVFHEstimation = <pcl_ftr.VFHEstimation_t *>vfhEstimation.me
        cVFHEstimation.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return vfhEstimation

    def make_RangeImage(self):
        rangeImages = RangeImages(self)
        # cdef pcl_rim.RangeImage_t *cRangeImage = <pcl_rim.RangeImage_t *>rangeImages.me
        return rangeImages

    def make_EuclideanClusterExtraction(self):
        euclideanclusterextraction = EuclideanClusterExtraction(self)
        cdef pcl_seg.EuclideanClusterExtraction_t *cEuclideanClusterExtraction = <pcl_seg.EuclideanClusterExtraction_t *>euclideanclusterextraction.me
        cEuclideanClusterExtraction.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return euclideanclusterextraction

    def make_GeneralizedIterativeClosestPoint(self):
        generalizedIterativeClosestPoint = GeneralizedIterativeClosestPoint(self)
        cdef pcl_reg.GeneralizedIterativeClosestPoint_t *cGeneralizedIterativeClosestPoint = <pcl_reg.GeneralizedIterativeClosestPoint_t *>generalizedIterativeClosestPoint.me
        cGeneralizedIterativeClosestPoint.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return generalizedIterativeClosestPoint

    def make_IterativeClosestPointNonLinear(self):
        iterativeClosestPointNonLinear = IterativeClosestPointNonLinear(self)
        cdef pcl_reg.IterativeClosestPointNonLinear_t *cIterativeClosestPointNonLinear = <pcl_reg.IterativeClosestPointNonLinear_t *>iterativeClosestPointNonLinear.me
        cIterativeClosestPointNonLinear.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return iterativeClosestPointNonLinear

    def make_IterativeClosestPoint(self):
        iterativeClosestPoint = IterativeClosestPoint(self)
        cdef pcl_reg.IterativeClosestPoint_t *cIterativeClosestPoint = <pcl_reg.IterativeClosestPoint_t *>iterativeClosestPoint.me
        cIterativeClosestPoint.setInputCloud(<cpp.shared_ptr[cpp.PointCloud[cpp.PointXYZ]]> self.thisptr_shared)
        return iterativeClosestPoint


###


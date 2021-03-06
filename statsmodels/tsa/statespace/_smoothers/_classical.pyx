#cython: boundscheck=False
#cython: wraparound=False
#cython: cdivision=False
"""
State Space Models

Author: Chad Fulton  
License: Simplified-BSD

Notes
-----

The dimensions used in all the BLAS / LAPACK calls below use the following
convention:

- The dimensions of the arrays *as they are to be manipulated* are all defined
  as model._k_*
- If the array in question is defined in the Statespace object
  (obs, obs_intercept, design, obs_cov, state_intercept, transition, selection,
  state_cov, selected_state_cov), then the dimension in-memory is defined as
  model._k_*
  This is because the in-memory shape of matrices changes according to whether
  or not data is missing and whether or not the generalized collapse transform
  is applied.
- If the array in question is defined in the Kalman filter object
  (forecast_*, filtered_*, predicted_*, etc.), then the dimension in-memory is
  defined as kfilter.k_*
  This is because the in-memory shape of matrices only changes according to
  filter_method.
- If the array in question is defined in the Kalman smoother object
  (smoothed_*, etc.), then the dimension in-memory is defined as kfilter.k_*
  This is because the in-memory shape of matrices only changes according to
  filter_method.

Thus, for example, a ?gemm call has the following signature:

dgemm(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc)

- m, n, and k are the dimensions *as they are to be manipulated*, and are
  always defined as model._k_*
- lda, ldb, and ldc are the *in-memory* dimension, and they are set as
  model._k_* if the array is defined in the Statespace object, otherwise
  (in either the filter or smoother cases) they are set as kfilter.k_*

Note that for ?copy calls, the number of elements to be copied is defined to be
the dimension in memory of the array that is being copied *from*.
"""

# Typical imports
import numpy as np
cimport numpy as np
from statsmodels.src.math cimport *
cimport scipy.linalg.cython_blas as blas
cimport scipy.linalg.cython_lapack as lapack

from statsmodels.tsa.statespace._kalman_smoother cimport (
    SMOOTHER_STATE, SMOOTHER_STATE_COV, SMOOTHER_DISTURBANCE,
    SMOOTHER_DISTURBANCE_COV
)

# ### Classical Kalman smoother
#
# The following are the above routines as defined in the conventional Kalman
# smoother.
#
# See Durbin and Koopman (2012) Chapter 4.6.1

cdef int ssmoothed_estimators_measurement_classical(sKalmanSmoother smoother, sKalmanFilter kfilter, sStatespace model) except *:
    cdef:
        int i, j, info
        int inc = 1
        np.float32_t alpha = 1.0
        np.float32_t beta = 0.0
        np.float32_t gamma = -1.0
        np.float32_t tmp

    # Factorize the predicted state covariance matrix
    blas.scopy(&kfilter.k_states2, &kfilter.predicted_state_cov[0,0,smoother.t+1], &inc,
                                            smoother._tmpL, &inc)
    lapack.spotrf("L", &kfilter.k_states, smoother._tmpL, &kfilter.k_states, &info)

    if info < 0:
        raise np.linalg.LinAlgError('Illegal value in predicted state'
                                    ' covariance matrix encountered at'
                                    ' period %d' % smoother.t)
    if info > 0:
        raise np.linalg.LinAlgError('Singular predicted state covariance'
                                    ' matrix encountered at period %d' %
                                    smoother.t)

    # Scaled smoothed estimator  
    # $r_t = P_{t+1}^{-1} (\hat \alpha_{t+1} - a_{t+1})$   
    # $(m \times 1) = (m \times m) [(m \times 1) - (m \times 1)]$
    # Note: save $r_t$ as _input_scaled_smoothed_estimator not as
    # _scaled_smoothed_estimator
    if smoother.t < model.nobs-1 and smoother.smoother_output & (SMOOTHER_STATE | SMOOTHER_DISTURBANCE):
        blas.scopy(&kfilter.k_states, &smoother.smoothed_state[0, smoother.t+1], &inc,
                                               smoother._input_scaled_smoothed_estimator, &inc)
        blas.saxpy(&kfilter.k_states, &gamma, &kfilter.predicted_state[0,smoother.t+1], &inc,
                                                       smoother._input_scaled_smoothed_estimator, &inc)

        lapack.spotrs("L", &kfilter.k_states, &inc, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

    # Scaled smoothed estimator covariance matrix  
    # $N_t = P_{t+1}^{-1} (P_{t+1} - V_{t+1}) P_{t+1}^{-1}
    # $(m \times m) = (m \times p) (p \times m) + (m \times m) (m \times m) (m \times m)$  
    # Note: save $N_t$ as _input_scaled_smoothed_estimator_cov not as
    # _scaled_smoothed_estimator_cov
    if smoother.t < model.nobs-1 and smoother.smoother_output & (SMOOTHER_STATE_COV | SMOOTHER_DISTURBANCE_COV):
        blas.scopy(&kfilter.k_states2, &kfilter.predicted_state_cov[0, 0, smoother.t+1], &inc,
                                                smoother._input_scaled_smoothed_estimator_cov, &inc)
        blas.saxpy(&kfilter.k_states2, &gamma, &smoother.smoothed_state_cov[0, 0, smoother.t+1], &inc,
                                                        smoother._input_scaled_smoothed_estimator_cov, &inc)

        lapack.spotrs("L", &kfilter.k_states, &kfilter.k_states, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

        # transpose
        for i in range(kfilter.k_states):
            for j in range(i, kfilter.k_states):
                if i == j:
                    continue
                tmp = smoother.scaled_smoothed_estimator_cov[i,j,smoother.t+1]
                smoother.scaled_smoothed_estimator_cov[i,j,smoother.t+1] = smoother.scaled_smoothed_estimator_cov[j,i,smoother.t+1]
                smoother.scaled_smoothed_estimator_cov[j,i,smoother.t+1] = tmp

        lapack.spotrs("L", &kfilter.k_states, &kfilter.k_states, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

    # Smoothing error  
    # $u_t = \\#_2 - K_t' r_t$  
    # $(p \times 1) = (p \times 1) - (p \times m) (m \times 1)$ 
    if smoother.smoother_output & (SMOOTHER_DISTURBANCE):
        if not model._nmissing == model.k_endog:
            blas.scopy(&kfilter.k_endog, kfilter._tmp2, &inc, smoother._smoothing_error, &inc)
        blas.sgemv("T", &model._k_states, &model._k_endog,
                  &gamma, kfilter._kalman_gain, &kfilter.k_states,
                          smoother._input_scaled_smoothed_estimator, &inc,
                  &alpha, smoother._smoothing_error, &inc)

    # $L_t = (T_t - K_t Z_t)$  
    # $(m \times m) = (m \times m) + (m \times p) (p \times m)$
    # (this is required for any type of smoothing)
    blas.scopy(&model._k_states2, model._transition, &inc, smoother._tmpL, &inc)
    blas.sgemm("N", "N", &model._k_states, &model._k_states, &model._k_endog,
              &gamma, kfilter._kalman_gain, &kfilter.k_states,
                      model._design, &model._k_endog,
              &alpha, smoother._tmpL, &kfilter.k_states)

cdef int ssmoothed_estimators_time_classical(sKalmanSmoother smoother, sKalmanFilter kfilter, sStatespace model):
  pass

cdef int ssmoothed_state_classical(sKalmanSmoother smoother, sKalmanFilter kfilter, sStatespace model):
    cdef int i, j
    cdef:
        int inc = 1
        np.float32_t alpha = 1.0
        np.float32_t beta = 0.0
        np.float32_t gamma = -1.0

    if (smoother.smoother_output & SMOOTHER_STATE) or (smoother.smoother_output & SMOOTHER_STATE_COV):
        blas.sgemm("N", "T", &model._k_states, &model._k_states, &model._k_states,
                  &alpha, &kfilter.filtered_state_cov[0, 0, smoother.t], &kfilter.k_states,
                          model._transition, &kfilter.k_states,
                  &beta, smoother._tmp0, &kfilter.k_states)

    # Smoothed state
    if smoother.smoother_output & SMOOTHER_STATE:
        # $\hat \alpha_t = a_t|t + P_t|t T_t' r_t$  
        # $(m \times 1) = (m \times 1) + (m \times m) (m \times 1)$  
        blas.scopy(&kfilter.k_states, &kfilter.filtered_state[0,smoother.t], &inc, smoother._smoothed_state, &inc)

        blas.sgemv("N", &model._k_states, &model._k_states,
                  &alpha, smoother._tmp0, &kfilter.k_states,
                          smoother._input_scaled_smoothed_estimator, &inc,
                  &alpha, smoother._smoothed_state, &inc)

    # Smoothed state covariance
    if smoother.smoother_output & SMOOTHER_STATE_COV:
        # $V_t = P_t|t [I - T_t' N_t T_t P_t|t]$  
        # $(m \times m) = (m \times m) [(m \times m) - (m \times m) (m \times m)]$  
        blas.sgemm("N", "T", &model._k_states, &model._k_states, &model._k_states,
              &alpha, smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states,
                      smoother._tmp0, &kfilter.k_states,
              &beta, smoother._tmpL2, &kfilter.k_states)
        blas.sgemm("T", "N", &model._k_states, &model._k_states, &model._k_states,
              &gamma, model._transition, &kfilter.k_states,
                      smoother._tmpL2, &kfilter.k_states,
              &beta, smoother._tmp0, &kfilter.k_states)
        for i in range(kfilter.k_states):
            smoother.tmp0[i,i] = 1 + smoother.tmp0[i,i]
        blas.sgemm("N", "N", &model._k_states, &model._k_states, &model._k_states,
              &alpha, &kfilter.filtered_state_cov[0,0,smoother.t], &kfilter.k_states,
                      smoother._tmp0, &kfilter.k_states,
              &beta, smoother._smoothed_state_cov, &kfilter.k_states)

# ### Classical Kalman smoother
#
# The following are the above routines as defined in the conventional Kalman
# smoother.
#
# See Durbin and Koopman (2012) Chapter 4.6.1

cdef int dsmoothed_estimators_measurement_classical(dKalmanSmoother smoother, dKalmanFilter kfilter, dStatespace model) except *:
    cdef:
        int i, j, info
        int inc = 1
        np.float64_t alpha = 1.0
        np.float64_t beta = 0.0
        np.float64_t gamma = -1.0
        np.float64_t tmp

    # Factorize the predicted state covariance matrix
    blas.dcopy(&kfilter.k_states2, &kfilter.predicted_state_cov[0,0,smoother.t+1], &inc,
                                            smoother._tmpL, &inc)
    lapack.dpotrf("L", &kfilter.k_states, smoother._tmpL, &kfilter.k_states, &info)

    if info < 0:
        raise np.linalg.LinAlgError('Illegal value in predicted state'
                                    ' covariance matrix encountered at'
                                    ' period %d' % smoother.t)
    if info > 0:
        raise np.linalg.LinAlgError('Singular predicted state covariance'
                                    ' matrix encountered at period %d' %
                                    smoother.t)

    # Scaled smoothed estimator  
    # $r_t = P_{t+1}^{-1} (\hat \alpha_{t+1} - a_{t+1})$   
    # $(m \times 1) = (m \times m) [(m \times 1) - (m \times 1)]$
    # Note: save $r_t$ as _input_scaled_smoothed_estimator not as
    # _scaled_smoothed_estimator
    if smoother.t < model.nobs-1 and smoother.smoother_output & (SMOOTHER_STATE | SMOOTHER_DISTURBANCE):
        blas.dcopy(&kfilter.k_states, &smoother.smoothed_state[0, smoother.t+1], &inc,
                                               smoother._input_scaled_smoothed_estimator, &inc)
        blas.daxpy(&kfilter.k_states, &gamma, &kfilter.predicted_state[0,smoother.t+1], &inc,
                                                       smoother._input_scaled_smoothed_estimator, &inc)

        lapack.dpotrs("L", &kfilter.k_states, &inc, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

    # Scaled smoothed estimator covariance matrix  
    # $N_t = P_{t+1}^{-1} (P_{t+1} - V_{t+1}) P_{t+1}^{-1}
    # $(m \times m) = (m \times p) (p \times m) + (m \times m) (m \times m) (m \times m)$  
    # Note: save $N_t$ as _input_scaled_smoothed_estimator_cov not as
    # _scaled_smoothed_estimator_cov
    if smoother.t < model.nobs-1 and smoother.smoother_output & (SMOOTHER_STATE_COV | SMOOTHER_DISTURBANCE_COV):
        blas.dcopy(&kfilter.k_states2, &kfilter.predicted_state_cov[0, 0, smoother.t+1], &inc,
                                                smoother._input_scaled_smoothed_estimator_cov, &inc)
        blas.daxpy(&kfilter.k_states2, &gamma, &smoother.smoothed_state_cov[0, 0, smoother.t+1], &inc,
                                                        smoother._input_scaled_smoothed_estimator_cov, &inc)

        lapack.dpotrs("L", &kfilter.k_states, &kfilter.k_states, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

        # transpose
        for i in range(kfilter.k_states):
            for j in range(i, kfilter.k_states):
                if i == j:
                    continue
                tmp = smoother.scaled_smoothed_estimator_cov[i,j,smoother.t+1]
                smoother.scaled_smoothed_estimator_cov[i,j,smoother.t+1] = smoother.scaled_smoothed_estimator_cov[j,i,smoother.t+1]
                smoother.scaled_smoothed_estimator_cov[j,i,smoother.t+1] = tmp

        lapack.dpotrs("L", &kfilter.k_states, &kfilter.k_states, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

    # Smoothing error  
    # $u_t = \\#_2 - K_t' r_t$  
    # $(p \times 1) = (p \times 1) - (p \times m) (m \times 1)$ 
    if smoother.smoother_output & (SMOOTHER_DISTURBANCE):
        if not model._nmissing == model.k_endog:
            blas.dcopy(&kfilter.k_endog, kfilter._tmp2, &inc, smoother._smoothing_error, &inc)
        blas.dgemv("T", &model._k_states, &model._k_endog,
                  &gamma, kfilter._kalman_gain, &kfilter.k_states,
                          smoother._input_scaled_smoothed_estimator, &inc,
                  &alpha, smoother._smoothing_error, &inc)

    # $L_t = (T_t - K_t Z_t)$  
    # $(m \times m) = (m \times m) + (m \times p) (p \times m)$
    # (this is required for any type of smoothing)
    blas.dcopy(&model._k_states2, model._transition, &inc, smoother._tmpL, &inc)
    blas.dgemm("N", "N", &model._k_states, &model._k_states, &model._k_endog,
              &gamma, kfilter._kalman_gain, &kfilter.k_states,
                      model._design, &model._k_endog,
              &alpha, smoother._tmpL, &kfilter.k_states)

cdef int dsmoothed_estimators_time_classical(dKalmanSmoother smoother, dKalmanFilter kfilter, dStatespace model):
  pass

cdef int dsmoothed_state_classical(dKalmanSmoother smoother, dKalmanFilter kfilter, dStatespace model):
    cdef int i, j
    cdef:
        int inc = 1
        np.float64_t alpha = 1.0
        np.float64_t beta = 0.0
        np.float64_t gamma = -1.0

    if (smoother.smoother_output & SMOOTHER_STATE) or (smoother.smoother_output & SMOOTHER_STATE_COV):
        blas.dgemm("N", "T", &model._k_states, &model._k_states, &model._k_states,
                  &alpha, &kfilter.filtered_state_cov[0, 0, smoother.t], &kfilter.k_states,
                          model._transition, &kfilter.k_states,
                  &beta, smoother._tmp0, &kfilter.k_states)

    # Smoothed state
    if smoother.smoother_output & SMOOTHER_STATE:
        # $\hat \alpha_t = a_t|t + P_t|t T_t' r_t$  
        # $(m \times 1) = (m \times 1) + (m \times m) (m \times 1)$  
        blas.dcopy(&kfilter.k_states, &kfilter.filtered_state[0,smoother.t], &inc, smoother._smoothed_state, &inc)

        blas.dgemv("N", &model._k_states, &model._k_states,
                  &alpha, smoother._tmp0, &kfilter.k_states,
                          smoother._input_scaled_smoothed_estimator, &inc,
                  &alpha, smoother._smoothed_state, &inc)

    # Smoothed state covariance
    if smoother.smoother_output & SMOOTHER_STATE_COV:
        # $V_t = P_t|t [I - T_t' N_t T_t P_t|t]$  
        # $(m \times m) = (m \times m) [(m \times m) - (m \times m) (m \times m)]$  
        blas.dgemm("N", "T", &model._k_states, &model._k_states, &model._k_states,
              &alpha, smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states,
                      smoother._tmp0, &kfilter.k_states,
              &beta, smoother._tmpL2, &kfilter.k_states)
        blas.dgemm("T", "N", &model._k_states, &model._k_states, &model._k_states,
              &gamma, model._transition, &kfilter.k_states,
                      smoother._tmpL2, &kfilter.k_states,
              &beta, smoother._tmp0, &kfilter.k_states)
        for i in range(kfilter.k_states):
            smoother.tmp0[i,i] = 1 + smoother.tmp0[i,i]
        blas.dgemm("N", "N", &model._k_states, &model._k_states, &model._k_states,
              &alpha, &kfilter.filtered_state_cov[0,0,smoother.t], &kfilter.k_states,
                      smoother._tmp0, &kfilter.k_states,
              &beta, smoother._smoothed_state_cov, &kfilter.k_states)

# ### Classical Kalman smoother
#
# The following are the above routines as defined in the conventional Kalman
# smoother.
#
# See Durbin and Koopman (2012) Chapter 4.6.1

cdef int csmoothed_estimators_measurement_classical(cKalmanSmoother smoother, cKalmanFilter kfilter, cStatespace model) except *:
    cdef:
        int i, j, info
        int inc = 1
        np.complex64_t alpha = 1.0
        np.complex64_t beta = 0.0
        np.complex64_t gamma = -1.0
        np.complex64_t tmp

    # Factorize the predicted state covariance matrix
    blas.ccopy(&kfilter.k_states2, &kfilter.predicted_state_cov[0,0,smoother.t+1], &inc,
                                            smoother._tmpL, &inc)
    lapack.cpotrf("L", &kfilter.k_states, smoother._tmpL, &kfilter.k_states, &info)

    if info < 0:
        raise np.linalg.LinAlgError('Illegal value in predicted state'
                                    ' covariance matrix encountered at'
                                    ' period %d' % smoother.t)
    if info > 0:
        raise np.linalg.LinAlgError('Singular predicted state covariance'
                                    ' matrix encountered at period %d' %
                                    smoother.t)

    # Scaled smoothed estimator  
    # $r_t = P_{t+1}^{-1} (\hat \alpha_{t+1} - a_{t+1})$   
    # $(m \times 1) = (m \times m) [(m \times 1) - (m \times 1)]$
    # Note: save $r_t$ as _input_scaled_smoothed_estimator not as
    # _scaled_smoothed_estimator
    if smoother.t < model.nobs-1 and smoother.smoother_output & (SMOOTHER_STATE | SMOOTHER_DISTURBANCE):
        blas.ccopy(&kfilter.k_states, &smoother.smoothed_state[0, smoother.t+1], &inc,
                                               smoother._input_scaled_smoothed_estimator, &inc)
        blas.caxpy(&kfilter.k_states, &gamma, &kfilter.predicted_state[0,smoother.t+1], &inc,
                                                       smoother._input_scaled_smoothed_estimator, &inc)

        lapack.cpotrs("L", &kfilter.k_states, &inc, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

    # Scaled smoothed estimator covariance matrix  
    # $N_t = P_{t+1}^{-1} (P_{t+1} - V_{t+1}) P_{t+1}^{-1}
    # $(m \times m) = (m \times p) (p \times m) + (m \times m) (m \times m) (m \times m)$  
    # Note: save $N_t$ as _input_scaled_smoothed_estimator_cov not as
    # _scaled_smoothed_estimator_cov
    if smoother.t < model.nobs-1 and smoother.smoother_output & (SMOOTHER_STATE_COV | SMOOTHER_DISTURBANCE_COV):
        blas.ccopy(&kfilter.k_states2, &kfilter.predicted_state_cov[0, 0, smoother.t+1], &inc,
                                                smoother._input_scaled_smoothed_estimator_cov, &inc)
        blas.caxpy(&kfilter.k_states2, &gamma, &smoother.smoothed_state_cov[0, 0, smoother.t+1], &inc,
                                                        smoother._input_scaled_smoothed_estimator_cov, &inc)

        lapack.cpotrs("L", &kfilter.k_states, &kfilter.k_states, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

        # transpose
        for i in range(kfilter.k_states):
            for j in range(i, kfilter.k_states):
                if i == j:
                    continue
                tmp = smoother.scaled_smoothed_estimator_cov[i,j,smoother.t+1]
                smoother.scaled_smoothed_estimator_cov[i,j,smoother.t+1] = smoother.scaled_smoothed_estimator_cov[j,i,smoother.t+1]
                smoother.scaled_smoothed_estimator_cov[j,i,smoother.t+1] = tmp

        lapack.cpotrs("L", &kfilter.k_states, &kfilter.k_states, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

    # Smoothing error  
    # $u_t = \\#_2 - K_t' r_t$  
    # $(p \times 1) = (p \times 1) - (p \times m) (m \times 1)$ 
    if smoother.smoother_output & (SMOOTHER_DISTURBANCE):
        if not model._nmissing == model.k_endog:
            blas.ccopy(&kfilter.k_endog, kfilter._tmp2, &inc, smoother._smoothing_error, &inc)
        blas.cgemv("T", &model._k_states, &model._k_endog,
                  &gamma, kfilter._kalman_gain, &kfilter.k_states,
                          smoother._input_scaled_smoothed_estimator, &inc,
                  &alpha, smoother._smoothing_error, &inc)

    # $L_t = (T_t - K_t Z_t)$  
    # $(m \times m) = (m \times m) + (m \times p) (p \times m)$
    # (this is required for any type of smoothing)
    blas.ccopy(&model._k_states2, model._transition, &inc, smoother._tmpL, &inc)
    blas.cgemm("N", "N", &model._k_states, &model._k_states, &model._k_endog,
              &gamma, kfilter._kalman_gain, &kfilter.k_states,
                      model._design, &model._k_endog,
              &alpha, smoother._tmpL, &kfilter.k_states)

cdef int csmoothed_estimators_time_classical(cKalmanSmoother smoother, cKalmanFilter kfilter, cStatespace model):
  pass

cdef int csmoothed_state_classical(cKalmanSmoother smoother, cKalmanFilter kfilter, cStatespace model):
    cdef int i, j
    cdef:
        int inc = 1
        np.complex64_t alpha = 1.0
        np.complex64_t beta = 0.0
        np.complex64_t gamma = -1.0

    if (smoother.smoother_output & SMOOTHER_STATE) or (smoother.smoother_output & SMOOTHER_STATE_COV):
        blas.cgemm("N", "T", &model._k_states, &model._k_states, &model._k_states,
                  &alpha, &kfilter.filtered_state_cov[0, 0, smoother.t], &kfilter.k_states,
                          model._transition, &kfilter.k_states,
                  &beta, smoother._tmp0, &kfilter.k_states)

    # Smoothed state
    if smoother.smoother_output & SMOOTHER_STATE:
        # $\hat \alpha_t = a_t|t + P_t|t T_t' r_t$  
        # $(m \times 1) = (m \times 1) + (m \times m) (m \times 1)$  
        blas.ccopy(&kfilter.k_states, &kfilter.filtered_state[0,smoother.t], &inc, smoother._smoothed_state, &inc)

        blas.cgemv("N", &model._k_states, &model._k_states,
                  &alpha, smoother._tmp0, &kfilter.k_states,
                          smoother._input_scaled_smoothed_estimator, &inc,
                  &alpha, smoother._smoothed_state, &inc)

    # Smoothed state covariance
    if smoother.smoother_output & SMOOTHER_STATE_COV:
        # $V_t = P_t|t [I - T_t' N_t T_t P_t|t]$  
        # $(m \times m) = (m \times m) [(m \times m) - (m \times m) (m \times m)]$  
        blas.cgemm("N", "T", &model._k_states, &model._k_states, &model._k_states,
              &alpha, smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states,
                      smoother._tmp0, &kfilter.k_states,
              &beta, smoother._tmpL2, &kfilter.k_states)
        blas.cgemm("T", "N", &model._k_states, &model._k_states, &model._k_states,
              &gamma, model._transition, &kfilter.k_states,
                      smoother._tmpL2, &kfilter.k_states,
              &beta, smoother._tmp0, &kfilter.k_states)
        for i in range(kfilter.k_states):
            smoother.tmp0[i,i] = 1 + smoother.tmp0[i,i]
        blas.cgemm("N", "N", &model._k_states, &model._k_states, &model._k_states,
              &alpha, &kfilter.filtered_state_cov[0,0,smoother.t], &kfilter.k_states,
                      smoother._tmp0, &kfilter.k_states,
              &beta, smoother._smoothed_state_cov, &kfilter.k_states)

# ### Classical Kalman smoother
#
# The following are the above routines as defined in the conventional Kalman
# smoother.
#
# See Durbin and Koopman (2012) Chapter 4.6.1

cdef int zsmoothed_estimators_measurement_classical(zKalmanSmoother smoother, zKalmanFilter kfilter, zStatespace model) except *:
    cdef:
        int i, j, info
        int inc = 1
        np.complex128_t alpha = 1.0
        np.complex128_t beta = 0.0
        np.complex128_t gamma = -1.0
        np.complex128_t tmp

    # Factorize the predicted state covariance matrix
    blas.zcopy(&kfilter.k_states2, &kfilter.predicted_state_cov[0,0,smoother.t+1], &inc,
                                            smoother._tmpL, &inc)
    lapack.zpotrf("L", &kfilter.k_states, smoother._tmpL, &kfilter.k_states, &info)

    if info < 0:
        raise np.linalg.LinAlgError('Illegal value in predicted state'
                                    ' covariance matrix encountered at'
                                    ' period %d' % smoother.t)
    if info > 0:
        raise np.linalg.LinAlgError('Singular predicted state covariance'
                                    ' matrix encountered at period %d' %
                                    smoother.t)

    # Scaled smoothed estimator  
    # $r_t = P_{t+1}^{-1} (\hat \alpha_{t+1} - a_{t+1})$   
    # $(m \times 1) = (m \times m) [(m \times 1) - (m \times 1)]$
    # Note: save $r_t$ as _input_scaled_smoothed_estimator not as
    # _scaled_smoothed_estimator
    if smoother.t < model.nobs-1 and smoother.smoother_output & (SMOOTHER_STATE | SMOOTHER_DISTURBANCE):
        blas.zcopy(&kfilter.k_states, &smoother.smoothed_state[0, smoother.t+1], &inc,
                                               smoother._input_scaled_smoothed_estimator, &inc)
        blas.zaxpy(&kfilter.k_states, &gamma, &kfilter.predicted_state[0,smoother.t+1], &inc,
                                                       smoother._input_scaled_smoothed_estimator, &inc)

        lapack.zpotrs("L", &kfilter.k_states, &inc, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

    # Scaled smoothed estimator covariance matrix  
    # $N_t = P_{t+1}^{-1} (P_{t+1} - V_{t+1}) P_{t+1}^{-1}
    # $(m \times m) = (m \times p) (p \times m) + (m \times m) (m \times m) (m \times m)$  
    # Note: save $N_t$ as _input_scaled_smoothed_estimator_cov not as
    # _scaled_smoothed_estimator_cov
    if smoother.t < model.nobs-1 and smoother.smoother_output & (SMOOTHER_STATE_COV | SMOOTHER_DISTURBANCE_COV):
        blas.zcopy(&kfilter.k_states2, &kfilter.predicted_state_cov[0, 0, smoother.t+1], &inc,
                                                smoother._input_scaled_smoothed_estimator_cov, &inc)
        blas.zaxpy(&kfilter.k_states2, &gamma, &smoother.smoothed_state_cov[0, 0, smoother.t+1], &inc,
                                                        smoother._input_scaled_smoothed_estimator_cov, &inc)

        lapack.zpotrs("L", &kfilter.k_states, &kfilter.k_states, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

        # transpose
        for i in range(kfilter.k_states):
            for j in range(i, kfilter.k_states):
                if i == j:
                    continue
                tmp = smoother.scaled_smoothed_estimator_cov[i,j,smoother.t+1]
                smoother.scaled_smoothed_estimator_cov[i,j,smoother.t+1] = smoother.scaled_smoothed_estimator_cov[j,i,smoother.t+1]
                smoother.scaled_smoothed_estimator_cov[j,i,smoother.t+1] = tmp

        lapack.zpotrs("L", &kfilter.k_states, &kfilter.k_states, smoother._tmpL, &kfilter.k_states,
                                                             smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states, &info)

        if info < 0:
            raise np.linalg.LinAlgError('Illegal value in predicted state'
                                        ' covariance matrix encountered at'
                                        ' period %d' % smoother.t)

    # Smoothing error  
    # $u_t = \\#_2 - K_t' r_t$  
    # $(p \times 1) = (p \times 1) - (p \times m) (m \times 1)$ 
    if smoother.smoother_output & (SMOOTHER_DISTURBANCE):
        if not model._nmissing == model.k_endog:
            blas.zcopy(&kfilter.k_endog, kfilter._tmp2, &inc, smoother._smoothing_error, &inc)
        blas.zgemv("T", &model._k_states, &model._k_endog,
                  &gamma, kfilter._kalman_gain, &kfilter.k_states,
                          smoother._input_scaled_smoothed_estimator, &inc,
                  &alpha, smoother._smoothing_error, &inc)

    # $L_t = (T_t - K_t Z_t)$  
    # $(m \times m) = (m \times m) + (m \times p) (p \times m)$
    # (this is required for any type of smoothing)
    blas.zcopy(&model._k_states2, model._transition, &inc, smoother._tmpL, &inc)
    blas.zgemm("N", "N", &model._k_states, &model._k_states, &model._k_endog,
              &gamma, kfilter._kalman_gain, &kfilter.k_states,
                      model._design, &model._k_endog,
              &alpha, smoother._tmpL, &kfilter.k_states)

cdef int zsmoothed_estimators_time_classical(zKalmanSmoother smoother, zKalmanFilter kfilter, zStatespace model):
  pass

cdef int zsmoothed_state_classical(zKalmanSmoother smoother, zKalmanFilter kfilter, zStatespace model):
    cdef int i, j
    cdef:
        int inc = 1
        np.complex128_t alpha = 1.0
        np.complex128_t beta = 0.0
        np.complex128_t gamma = -1.0

    if (smoother.smoother_output & SMOOTHER_STATE) or (smoother.smoother_output & SMOOTHER_STATE_COV):
        blas.zgemm("N", "T", &model._k_states, &model._k_states, &model._k_states,
                  &alpha, &kfilter.filtered_state_cov[0, 0, smoother.t], &kfilter.k_states,
                          model._transition, &kfilter.k_states,
                  &beta, smoother._tmp0, &kfilter.k_states)

    # Smoothed state
    if smoother.smoother_output & SMOOTHER_STATE:
        # $\hat \alpha_t = a_t|t + P_t|t T_t' r_t$  
        # $(m \times 1) = (m \times 1) + (m \times m) (m \times 1)$  
        blas.zcopy(&kfilter.k_states, &kfilter.filtered_state[0,smoother.t], &inc, smoother._smoothed_state, &inc)

        blas.zgemv("N", &model._k_states, &model._k_states,
                  &alpha, smoother._tmp0, &kfilter.k_states,
                          smoother._input_scaled_smoothed_estimator, &inc,
                  &alpha, smoother._smoothed_state, &inc)

    # Smoothed state covariance
    if smoother.smoother_output & SMOOTHER_STATE_COV:
        # $V_t = P_t|t [I - T_t' N_t T_t P_t|t]$  
        # $(m \times m) = (m \times m) [(m \times m) - (m \times m) (m \times m)]$  
        blas.zgemm("N", "T", &model._k_states, &model._k_states, &model._k_states,
              &alpha, smoother._input_scaled_smoothed_estimator_cov, &kfilter.k_states,
                      smoother._tmp0, &kfilter.k_states,
              &beta, smoother._tmpL2, &kfilter.k_states)
        blas.zgemm("T", "N", &model._k_states, &model._k_states, &model._k_states,
              &gamma, model._transition, &kfilter.k_states,
                      smoother._tmpL2, &kfilter.k_states,
              &beta, smoother._tmp0, &kfilter.k_states)
        for i in range(kfilter.k_states):
            smoother.tmp0[i,i] = 1 + smoother.tmp0[i,i]
        blas.zgemm("N", "N", &model._k_states, &model._k_states, &model._k_states,
              &alpha, &kfilter.filtered_state_cov[0,0,smoother.t], &kfilter.k_states,
                      smoother._tmp0, &kfilter.k_states,
              &beta, smoother._smoothed_state_cov, &kfilter.k_states)

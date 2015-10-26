# GLM for a Bernoulli outcome
data {
  # dimensions
  int<lower=0> K;                # number of predictors
  int<lower=1> N[2];             # number of observations where y = 0 and y = 1 respectively
  vector[K] xbar;                # vector of column-means of rbind(X0, X1)
  matrix[N[1],K] X0;             # centered (by xbar) predictor matrix | y = 0
  matrix[N[2],K] X1;             # centered (by xbar) predictor matrix | y = 1
  int<lower=0,upper=1> prior_PD; # flag indicating whether to draw from the prior predictive
  
  # intercept
  int<lower=0,upper=1> has_intercept; # 0 = no, 1 = yes
  
  # glmer stuff, see table 3 of
  # https://cran.r-project.org/web/packages/lme4/vignettes/lmer.pdf
  int<lower=0> t;                   # num. terms (maybe 0) with a | in the glmer formula
  int<lower=1> p[t];                # num. variables on the LHS of each |
  int<lower=1> l[t];                # num. levels for the factor(s) on the RHS of each |
  int<lower=0> q;                   # conceptually equals \sum_{i=1}^t p_i \times l_i
  int<lower=0> num_non_zero[2];     # number of non-zero elements in the Z matrices
  vector[num_non_zero[1]] w0;       # non-zero elements in the implicit Z0 matrix
  vector[num_non_zero[2]] w1;       # non-zero elements in the implicit Z1 matrix
  int<lower=0> v0[num_non_zero[1]]; # column indices for w0
  int<lower=0> v1[num_non_zero[2]]; # column indices for w1
  int<lower=0> u0[(N[1]+1)*(t>0)];  # where the non-zeros start in each row of Z0
  int<lower=0> u1[(N[2]+1)*(t>0)];  # where the non-zeros start in each row of Z1
  int<lower=0> len_theta_L;         # length of the theta_L vector

  # link function from location to linear predictor
  int<lower=1,upper=5> link;
  
  # weights
  int<lower=0,upper=1> has_weights; # 0 = No, 1 = Yes
  vector[N[1] * has_weights] weights0;
  vector[N[2] * has_weights] weights1;
  
  # offset
  int<lower=0,upper=1> has_offset;  # 0 = No, 1 = Yes
  vector[N[1] * has_offset] offset0;
  vector[N[2] * has_offset] offset1;

  # prior family: 0 = none, 1 = normal, 2 = student_t, 3 = hs, 4 = hs_plus
  int<lower=0,upper=4> prior_dist;
  int<lower=0,upper=2> prior_dist_for_intercept;
  
  # hyperparameter values
  vector<lower=0>[K] prior_scale;
  real<lower=0> prior_scale_for_intercept;
  vector[K] prior_mean;
  real prior_mean_for_intercept;
  vector<lower=0>[K] prior_df;
  real<lower=0> prior_df_for_intercept;

  # hyperparameters for glmer stuff; if t > 0 priors are mandatory
  vector<lower=0>[t] shape; 
  vector<lower=0>[t] scale;
  int<lower=0> len_concentration;
  real<lower=0> concentration[len_concentration];
  int<lower=0> len_regularization;
  real<lower=0> regularization[len_regularization];
}
transformed data {
  int NN;
  int<lower=0> hs;
  int<lower=0> len_z_T;
  int<lower=0> len_var_group;
  int<lower=0> len_rho;
  real<lower=0> delta[len_concentration];
  int<lower=1> pos;
  
  NN <- N[1] + N[2];
  if (prior_dist <=  2)     hs <- 0;
  else if (prior_dist == 3) hs <- 2;
  else if (prior_dist == 4) hs <- 4;
  len_z_T <- 0;
  len_var_group <- sum(p) * (t > 0);
  len_rho <- sum(p) - t;
  pos <- 1;
  for (i in 1:t) {
    if (p[i] > 1) {
      for (j in 1:p[i]) {
        delta[pos] <- concentration[j];
        pos <- pos + 1;
      }
    }
    for (j in 3:p[i]) len_z_T <- len_z_T + p[i] - 1;
  }
}
parameters {
  vector[K] z_beta;
  real<upper=if_else(link == 4, 0, positive_infinity())> gamma[has_intercept];
  real<lower=0> global[hs];
  vector<lower=0>[K] local[hs];
  vector[q] z_b;
  vector[len_z_T] z_T;
  vector<lower=0,upper=1>[len_rho] rho;
  vector<lower=0>[len_concentration] zeta;
  vector<lower=0>[t] tau;
}
transformed parameters {
  vector[K] beta;
  vector[q] b;
  vector[len_theta_L] theta_L;
  if (prior_dist == 0) beta <- z_beta;
  else if (prior_dist <= 2) beta <- z_beta .* prior_scale + prior_mean;
  else if (prior_dist == 3) {
    vector[K] lambda;
    for (k in 1:K) lambda[k] <- local[1][k] * sqrt(local[2][k]);
    beta <- z_beta .* lambda * global[1]    * sqrt(global[2]);
  }
  else if (prior_dist == 4) {
    vector[K] lambda;
    vector[K] lambda_plus;
    for (k in 1:K) {
      lambda[k] <- local[1][k] * sqrt(local[2][k]);
      lambda_plus[k] <- local[3][k] * sqrt(local[4][k]);
    }
    beta <- z_beta .* lambda .* lambda_plus * global[1] * sqrt(global[2]);
  }
  if (t > 0) {
    theta_L <- make_theta_L(len_theta_L, p, 1.0, tau, scale, zeta, rho, z_T);
    b <- make_b(z_b, theta_L, p, l);
  }
}
model {
  vector[N[1]] eta0;
  vector[N[2]] eta1;
  if (K > 0) {
    eta0 <- X0 * beta;
    eta1 <- X1 * beta;
  }
  else {
    eta0 <- rep_vector(0.0, N[1]);
    eta1 <- rep_vector(0.0, N[2]);
  }
  if (has_offset == 1) {
    eta0 <- eta0 + offset0;
    eta1 <- eta1 + offset1;
  }
  if (t > 0) {
    eta0 <- eta0 + csr_matrix_times_vector(N[1], q, w0, v0, u0, b);
    eta1 <- eta1 + csr_matrix_times_vector(N[2], q, w1, v1, u1, b);
  }
  if (has_intercept == 1) {
    if (link != 4) {
      eta0 <- gamma[1] + eta0;
      eta1 <- gamma[1] + eta1;
    }
    else {
      real shift;
      shift <- fmax(max(eta0), max(eta1));
      eta0 <- gamma[1] + eta0 - shift;
      eta1 <- gamma[1] + eta1 - shift;
    }
  }
  
  // Log-likelihood 
  if (has_weights == 0 && prior_PD == 0) { # unweighted log-likelihoods
    real dummy; # irrelevant but useful for testing
    dummy <- ll_bern_lp(eta0, eta1, link, N);
  }
  else if (prior_PD == 0) { # weighted log-likelihoods
    increment_log_prob(dot_product(weights0, pw_bern(0, eta0, link)));
    increment_log_prob(dot_product(weights1, pw_bern(1, eta1, link)));
  }
  
  // Log-priors for coefficients
  if      (prior_dist == 1) z_beta ~ normal(0, 1);
  else if (prior_dist == 2) z_beta ~ student_t(prior_df, 0, 1);
  else if (prior_dist == 3) { # hs
    z_beta ~ normal(0,1);
    local[1] ~ normal(0,1);
    local[2] ~ inv_gamma(0.5 * prior_df, 0.5 * prior_df);
    global[1] ~ normal(0,1);
    global[2] ~ inv_gamma(0.5, 0.5);
  }
  else if (prior_dist == 4) { # hs+
    z_beta ~ normal(0,1);
    local[1] ~ normal(0,1);
    local[2] ~ inv_gamma(0.5 * prior_df, 0.5 * prior_df);
    local[3] ~ normal(0,1);
    // unorthodox useage of prior_scale as another df hyperparameter
    local[4] ~ inv_gamma(0.5 * prior_scale, 0.5 * prior_scale);
    global[1] ~ normal(0,1);
    global[2] ~ inv_gamma(0.5, 0.5);
  }
  /* else prior_dist is 0 and nothing is added */
   
  // Log-prior for intercept  
  if (has_intercept == 1) {
    if (prior_dist_for_intercept == 1) # normal
      gamma ~ normal(prior_mean_for_intercept, prior_scale_for_intercept);
    else if (prior_dist_for_intercept == 2) # student_t
      gamma ~ student_t(prior_df_for_intercept, prior_mean_for_intercept, 
                        prior_scale_for_intercept);
    /* else prior_dist = 0 and nothing is added */
  }
  
  if (t > 0) {
    int pos_reg;
    int pos_rho;
    z_b ~ normal(0,1);
    z_T ~ normal(0,1);
    pos_reg <- 1;
    pos_rho <- 1;
    for (i in 1:t) if (p[i] > 1) {
      vector[p[i] - 1] shape1;
      vector[p[i] - 1] shape2;
      real nu;
      nu <- regularization[pos_reg] + 0.5 * (p[i] - 2);
      pos_reg <- pos_reg + 1;
      shape1[1] <- nu;
      shape2[1] <- nu;
      for (j in 2:(p[i]-1)) {
        nu <- nu - 0.5;
        shape1[j] <- 0.5 * j;
        shape2[j] <- nu;
      }
      segment(rho, pos_rho, p[i] - 1) ~ beta(shape1,shape2);
      pos_rho <- pos_rho + p[i] - 1;
    }
    zeta ~ gamma(delta, 1);
    tau ~ gamma(shape, 1);
  }
}
generated quantities {
  real alpha[has_intercept];
  real mean_PPD;
  if (has_intercept == 1) {
    alpha[1] <- gamma[1] - dot_product(xbar, beta);
  }
  mean_PPD <- 0;
  {
    vector[N[1]] eta0; 
    vector[N[2]] eta1;
    vector[N[1]] pi0;
    vector[N[2]] pi1;
    if (K > 0) {
      eta0 <- X0 * beta;
      eta1 <- X1 * beta;
    }
    else {
      eta0 <- rep_vector(0.0, N[1]);
      eta1 <- rep_vector(0.0, N[2]);
    }
    if (has_offset == 1) {
      eta0 <- eta0 + offset0;
      eta1 <- eta1 + offset1;
    }
    if (t > 0) {
      eta0 <- eta0 + csr_matrix_times_vector(N[1], q, w0, v0, u0, b);
      eta1 <- eta1 + csr_matrix_times_vector(N[2], q, w1, v1, u1, b);
    }
    if (has_intercept == 1) {
      if (link != 4) {
        eta0 <- gamma[1] + eta0;
        eta1 <- gamma[1] + eta1;
      }      
      else {
        real shift;
        shift <- fmax(max(eta0), max(eta1));
        eta0 <- gamma[1] + eta0 - shift;
        eta1 <- gamma[1] + eta1 - shift;
        alpha[1] <- alpha[1] - shift;
      }
    }
    pi0 <- linkinv_bern(eta0, link);
    pi1 <- linkinv_bern(eta1, link);
    for (n in 1:N[1]) mean_PPD <- mean_PPD + bernoulli_rng(pi0[n]);
    for (n in 1:N[2]) mean_PPD <- mean_PPD + bernoulli_rng(pi1[n]);
    mean_PPD <- mean_PPD / NN;
  }
}

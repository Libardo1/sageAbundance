#' Estimate model parameters in GLMM using rstan with no environmental covariates
#' 
#' @author Andrew Tredennick
#' @param y Vector of responses (cover observations)
#' @param lag Vector of lag response for temporal response (previous year's cover)
#' @param K Spatial field matrix
#' @param cellid Vector of unique ID's for each spatial cell, replicate through time
#' @param iters Number of MCMC iterations to run
#' @param inits A list of lists whose length is equal to number of chains. Elements
#'              include initial values for parameters to be estimated.
#' @param warmup Number of MCMC iterations to throw out before sampling (< iters)
#' @param nchains Number of MCMC chains to sample
#' @export
#' @return A list with ggs object with MCMC values from rstan and 
#'          Rhat values for each parameter.
model_nocovars <- function(y, lag, K, X, cellid, iters=2000, warmup=1000, nchains=1, inits){
  ##  Stan C++ model
  model_string <- "
  data{
    int<lower=0> nobs; // number of observations
    int<lower=0> ncovs; // number of climate covariates
    int<lower=0> nknots; // number of interpolation knots
    int<lower=0> ncells; // number of cells
    int<lower=0> cellid[nobs]; // cell id
    int<lower=0> dK1; // row dim for K
    int<lower=0> dK2; // column dim for K
    int y[nobs]; // observation vector
    int lag[nobs]; // lag cover vector
    matrix[dK1,dK2] K; // spatial field matrix
    matrix[nobs,ncovs] X; // spatial field matrix
  }
  parameters{
    real int_mu;
    real<lower=0> beta_mu;
    real<lower=0.000001> sig_a;
    real<lower=0.000001> sig_mu;
    vector[nknots] alpha;
    vector[nobs] lambda;
    vector[ncovs] beta;
  }
  transformed parameters{
    vector[ncells] eta;
    vector[nobs] mu;
    vector[nobs] climEffs;
    eta <- K*alpha;
    climEffs <- X*beta;
    for(n in 1:nobs)
    mu[n] <- int_mu + beta_mu*lag[n] + climEffs[n] + eta[cellid[n]];
  }
  model{
    // Priors
    alpha ~ normal(0,sig_a);
    sig_a ~ cauchy(0, 5);
    sig_mu ~ cauchy(0, 5);
    int_mu ~ normal(0,100);
    beta_mu ~ normal(0,10);
    beta ~ normal(0,10);
    // Likelihood
    lambda ~ normal(mu, sig_mu);
    y ~ poisson(exp(lambda));
  }
  "
  datalist <- list(y=y, lag=lag, nobs=length(lag), ncells=length(unique(cellid)),
                   cellid=cellid, nknots=ncol(K), K=K, dK1=nrow(K), dK2=ncol(K),
                   X=X, ncovs=ncol(X))
  pars <- c("int_mu", "beta_mu",  "alpha", "beta", "sig_mu", "sig_a")
  
  # Compile the model
  mcmc_samples <- stan(model_code=model_string, data=datalist,
                       pars=pars, chains=0)
  
  # Run parallel chains
  rng_seed <- 123
  sflist <-
    mclapply(1:nchains, mc.cores=nchains,
             function(i) stan(fit=mcmc_samples, data=datalist, pars=pars,
                              seed=rng_seed, chains=nchains, chain_id=i, refresh=-1,
                              iter=iters, warmup=warmup, init=list(inits[[i]])))
  fit <- sflist2stanfit(sflist)
  long <- ggs(fit)
#   stansumm <- as.data.frame(summary(fit)["summary"])
#   rhats <- stansumm["summary.Rhat"]
#   return_list <- list(mcmc=long, rhat=rhats)
  return(long)
}
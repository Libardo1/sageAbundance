##  Script to run sage abundance model through time, starting
##  at the last observation. Requires time series of climate
##  projections.

##  Author:       Andrew Tredennick
##  Email:        atredenn@gmail.com
##  Date created: 10-08-2015


### Clear the workspace
rm(list=ls())



####
####  Set some global simulation settings --------------------------------------
####
parameter_reps <- 50
clim_vars <- c("pptLag", "ppt1", "ppt2", "TmeanSpr1", "TmeanSpr2")


####
####  Load necessary libraries -------------------------------------------------
####
library(sageAbundance)
library(plyr)
library(reshape2)

#TODO: get sage Abundance functions to load!! Until then...
source("../R/clim_proj_format_funcs.R")



####
####  Read in percent cover file, climate projections, MCMC output, K.data -----
####
obs_data <- read.csv("../data/wy_sagecover_subset_noNA.csv")
obs_data <- subset(obs_data, Year>1984) # subsets out NA CoverLag values
temp_projs <- readRDS("../data/CMIP5_yearly_project_temperature.RDS")
ppt_projs <- readRDS("../data/CMIP5_yearly_project_precipitation.RDS")
mcmc_outs <- readRDS("../results/poissonSage_randYear_mcmc.RDS")
load("../results/Knot_cell_distances_subset.Rdata")
K <- K.data$K

### Only keep models with rcp45, 60, and 85 scenarios
allmods <- unique(temp_projs$model)
keeps <- character(length(allmods))
my_scens <- c("rcp45", "rcp60", "rcp85")
for(i in 1:length(allmods)){
  tmp <- subset(temp_projs, model==allmods[i])
  tmp.scns <- unique(tmp$scenario)
  flag <- length(which(my_scens %in% tmp.scns == FALSE))
  ifelse(flag>0, keeps[i]<-"no", keeps[i]<-"yes")
}
modelkeeps <- data.frame(model=allmods,
                         allscenarios=keeps)
my_mods <- modelkeeps[which(modelkeeps$allscenarios=="yes"),"model"]

temp_projs <- subset(temp_projs, model %in% my_mods)
ppt_projs <- subset(ppt_projs, model %in% my_mods)

####
####  Subset out observed climate; get scaling mean and sd ---------_-----------
####
obs_clim <- obs_data[,c("Year",clim_vars)]
obs_clim <- unique(obs_clim)
obs_clim_means <- colMeans(obs_clim[,clim_vars])
obs_clim_sds <- apply(obs_clim[,clim_vars], 2, sd)
obs_clim_scalers <- data.frame(variable = clim_vars,
                               means = obs_clim_means,
                               sdevs = obs_clim_sds)



####
####  Fit Colonization Logistic Model for 0% Cover Cells -----------------------
####
# Get data structure right
growD <- subset(obs_data, Year>1984) # get rid of NA lagcover years
growD$Cover <- round(growD$Cover,0) # round for count-like data
growD$CoverLag <- round(growD$CoverLag,0) # round for count-like data

colD <- growD[which(growD$CoverLag == 0), ]
colD$colonizes <- ifelse(colD$Cover==0, 0, 1)
col.fit <- glm(colonizes ~ 1, data=colD, family = "binomial")
col.intercept <- as.numeric(coef(col.fit))
antilogit <- function(x) { exp(x) / (1 + exp(x) ) }
avg.new.cover <- round(mean(colD[which(colD$Cover>0),"Cover"]),0)



####
####  Define simulation function -----------------------------------------------
####
iterate_sage <- function(N, int, beta.dens, beta.clim, eta, weather,
                         col.intercept, avg_new_cover){
  dens.dep <- beta.dens*log(N)                   # density dependent effect
  clim.effs <- sum(beta.clim*weather)            # climate effect
  mutmp <- exp(int + dens.dep + clim.effs + eta) # deterministic outcome
  tmp.out <- rpois(n = length(eta), lambda = mutmp) # probabilistic estimate
  
  ## Colonization Process
  zeros <- which(N==0)
  colonizers <- rbinom(length(zeros), size = 1, antilogit(col.intercept))
  colonizer.cover <- colonizers*avg_new_cover
  tmp.out[zeros] <- colonizer.cover
  Nout <- tmp.out
  return(Nout) # return the forecast
}



####
####  Begin simulation set up --------------------------------------------------
####
last_year <- max(obs_data$Year)
last_obs <- subset(obs_data, Year == last_year)
all_models <- unique(temp_projs$model)
all_scenarios <- c("rcp45", "rcp60", "rcp85")
sim_years <- c((last_year+1):max(temp_projs$Year))
num_sims <- length(sim_years)

nchains <- length(unique(mcmc_outs$chain))
niters <- length(unique(mcmc_outs$mcmc_iter))
dogrid <- expand.grid(1:niters, 1:nchains)



####
####  First forecast using point estimates of parameters for mean --------------
####
##  Get parameter point estimates
mean_params <- ddply(mcmc_outs, .(Parameter), summarise,
                     value = mean(value))
alphas <- mean_params[grep("alpha", mean_params$Parameter),"value"]
beta_clims <- mean_params[grep("beta", mean_params$Parameter),"value"][2:6]
eta <- K%*%alphas
beta_mu <- mean_params[mean_params$Parameter=="beta_mu","value"]
int_mu <- mean_params[mean_params$Parameter=="int_mu","value"]
sd_int <- mean_params[mean_params$Parameter=="sig_yr","value"]

##  Loop over model-scenarios
count <- 1
for(do_model in all_models){
  
  for(do_scenario in all_scenarios){
    
    temp_now <- subset(temp_projs, scenario==do_scenario & model==do_model)
    ppt_now <- subset(ppt_projs, scenario==do_scenario & model==do_model)
    climate_now <- format_climate(tdata = temp_now, 
                                  pdata = ppt_now, 
                                  years = sim_years)
    
    # Scale climate predictors
    climate_now["pptLag"] <- (climate_now["pptLag"] - obs_clim_means["pptLag"])/obs_clim_sds["pptLag"]
    climate_now["ppt1"] <- (climate_now["ppt1"] - obs_clim_means["ppt1"])/obs_clim_sds["ppt1"]
    climate_now["ppt2"] <- (climate_now["ppt2"] - obs_clim_means["ppt2"])/obs_clim_sds["ppt2"]
    climate_now["TmeanSpr1"] <- (climate_now["TmeanSpr1"] - obs_clim_means["TmeanSpr1"])/obs_clim_sds["TmeanSpr1"]
    climate_now["TmeanSpr2"] <- (climate_now["TmeanSpr2"] - obs_clim_means["TmeanSpr2"])/obs_clim_sds["TmeanSpr2"]
    
    # Create storage matrix for population
    n_save <- array(dim = c(1, num_sims+1, nrow(last_obs)))
    n_save[,1,] <- last_obs$Cover # set first record to last observation
    
    for(t in 2:num_sims){
      
      weather <- climate_now[t-1, clim_vars] #t-1 since clim data starts in 2012
      int_now <- rnorm(1, int_mu, sd_int)
      n_save[1,t,] <- iterate_sage(N = n_save[1,t-1,], 
                                   int = int_now, 
                                   beta.dens = beta_mu,
                                   beta.clim = beta_clims,
                                   eta = eta,
                                   weather = weather,
                                   col.intercept = col.intercept,
                                   avg_new_cover = avg.new.cover)
      
    } # next year (t)
    
    file <- paste0(do_model,"_", do_scenario, "_yearly_forecastsMEAN.RDS")
    path <- "../results/yearlyforecasts/"
    saveRDS(n_save, paste0(path,file))
    
    print(paste("Done with", do_model, do_scenario, "MEAN run"))
    
  } # next scenario
  
  print(paste(count, "of", length(all_models), "GCMs"))
  count <- count+1
  
} # next model




####
####  Begin looping: parameters within years within scenario within model ------
####
count <- 1
for(do_model in all_models){
  
  for(do_scenario in all_scenarios){
    
    temp_now <- subset(temp_projs, scenario==do_scenario & model==do_model)
    ppt_now <- subset(ppt_projs, scenario==do_scenario & model==do_model)
    climate_now <- format_climate(tdata = temp_now, 
                                  pdata = ppt_now, 
                                  years = sim_years)
    
    # Scale climate predictors
    climate_now["pptLag"] <- (climate_now["pptLag"] - obs_clim_means["pptLag"])/obs_clim_sds["pptLag"]
    climate_now["ppt1"] <- (climate_now["ppt1"] - obs_clim_means["ppt1"])/obs_clim_sds["ppt1"]
    climate_now["ppt2"] <- (climate_now["ppt2"] - obs_clim_means["ppt2"])/obs_clim_sds["ppt2"]
    climate_now["TmeanSpr1"] <- (climate_now["TmeanSpr1"] - obs_clim_means["TmeanSpr1"])/obs_clim_sds["TmeanSpr1"]
    climate_now["TmeanSpr2"] <- (climate_now["TmeanSpr2"] - obs_clim_means["TmeanSpr2"])/obs_clim_sds["TmeanSpr2"]
    
    # Create storage matrix for population
    n_save <- array(dim = c(parameter_reps, num_sims+1, nrow(last_obs)))
    # n_save <- array(dim = c(nrow(dogrid), num_sims+1, nrow(last_obs)))
    n_save[,1,] <- last_obs$Cover # set first record to last observation
    
      
    for(i in 1:parameter_reps){
      randchain <- sample(1:nchains, 1)
      randiter <- sample(1:niters, 1)
#       randchain <- dogrid[i,2]
#       randiter <- dogrid[i,1]
      params_now <- subset(mcmc_outs, chain==randchain & mcmc_iter==randiter)
      alphas <- params_now[grep("alpha", params_now$Parameter), "value"]
      int_mu <- params_now[grep("int_mu", params_now$Parameter), "value"]
      sd_int <- params_now[grep("sig_yr", params_now$Parameter), "value"]
      beta_mu <- params_now[grep("beta_mu", params_now$Parameter), "value"]
      beta_clims <- params_now[grep("beta.", params_now$Parameter), "value"][2:6]
      eta_now <-  K%*%as.numeric(unlist(alphas))
        
        for(t in 2:num_sims){
          
          weather <- climate_now[t-1, clim_vars] #t-1 since clim data starts in 2012
          int_now <- rnorm(1, int_mu, sd_int)
          n_save[i,t,] <- iterate_sage(N = n_save[i,t-1,], 
                                       int = int_now, 
                                       beta.dens = beta_mu,
                                       beta.clim = beta_clims,
                                       eta = eta_now,
                                       weather = weather,
                                       col.intercept = col.intercept,
                                       avg_new_cover = avg.new.cover)
        
      } # next year (t)
      
    } # next parameter set
    
    file <- paste0(do_model,"_", do_scenario, "_yearly_forecasts.RDS")
    path <- "../results/yearlyforecasts/"
    saveRDS(n_save, paste0(path,file))
    
    print(paste("Done with", do_model, do_scenario))
    print(paste(count, "of", length(all_models)))
    
  } # next scenario
  count <- count+1
} # next model


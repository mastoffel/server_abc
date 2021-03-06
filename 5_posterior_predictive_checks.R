# Start of the analysis: coalescent simulations. Uses strataG functions as interface.
# See strataG manual on how to install fastsimcoal26, which is needed for 
# the following script.

library(strataG)
library(dplyr)
library(parallel)

# posterior predictive checks
library(tidyr)
library(dplyr)
library(readr)
# load abc posterior data
load("abc_estimates/abc_10000kbot500_bot_complete_30.RData")
abc_bot <- unnest(abc_complete) %>% 
  mutate(post_mod = "bot")
load("abc_estimates/abc_10000kbot500_neut_complete_30.RData")
abc_neut <- unnest(abc_complete) %>% 
  mutate(post_mod = "neut")
# load parameter distributions
# abc_params <- fread("data/processed/abc_estimates/sims_1500k_params.txt")

# model selection
mod_select <- read_delim("results/model_probs/sims_10000kbot500_model_selection_30.txt",
                         delim = " ", col_names = c("species", "bot", "neut"), skip = 1) %>%
                        mutate(mod = ifelse(bot > 0.5, "bot", "neut")) %>%
                        select(species, mod)
# 
# # put all abc results together
abc_full <- rbind(abc_bot, abc_neut) 
# %>% 
#               left_join(mod_select, by = "species")

# number of simulations for posterior predictive check
num_sim <- 500
# species <- "antarctic_fur_seal"

abc_pars <- abc_full %>% 
  group_by(species, pars) %>% 
  sample_n(num_sim) %>% 
  select(species, pars, unadj_vals, post_mod) %>% 
  mutate(i = row_number()) %>% 
  tidyr::spread(pars, unadj_vals) 



#%>% 
#  filter(species == !!species)



# number of coalescent simulations
# original 10000000

# create data.frame with all parameter values ---------------
# sample size
sample_size <- rep(40, num_sim)
# number of loci
num_loci <- rep(10, num_sim)

# put posterior parameters into data.frame
all_N <- data.frame("pop_size" = abc_pars$pop_size, "nbot" = abc_pars$nbot, "nhist" = abc_pars$nhist)

# calculate popsizes relative to current effective popsize
all_N <- mutate(all_N, nbot_prop = nbot / pop_size)
all_N <- mutate(all_N, nhist_bot_prop = nhist / nbot)
all_N <- mutate(all_N, nhist_neut_prop = nhist / pop_size)

# simulate vectors for end and start of bottleneck
# min generation time is 6 years, max is 21.6 in the Pinnipeds
# make sure that the end of the bottleneck is always later (or earlier in generations backwards)
# than the start of the bottleneck

all_t <- data.frame("tbotend" = abc_pars$tbotend, "tbotstart" = abc_pars$tbotstart)

# mutation model
# mutation rate
mut_rate <- abc_pars$mut_rate
# parameter of the geometric distribution: decides about the proportion 
# of multistep mutations
gsm_param <- abc_pars$gsm_param
range_constraint <- rep(30, num_sim)

post_mod <- abc_pars$post_mod

all_params <- data.frame(sample_size, num_loci, all_N, all_t, mut_rate, gsm_param, 
                         range_constraint, param_num = 1:num_sim, post_mod) %>% 
                  mutate(post_mod = ifelse(post_mod == "bot", 1, 0))
str(all_params)


run_sims <- function(param_set){
  
  model <- as.character(param_set[["post_mod"]])
  lab <- as.character(param_set[["param_num"]])
  pop_info <- strataG::fscPopInfo(pop.size = param_set[["pop_size"]], sample.size = param_set[["sample_size"]])
  mig_rates <- matrix(0)
  
  # 1 if for bottleneck
  if (model == 1){
    hist_ev <- strataG::fscHistEv(
      num.gen = c(param_set[["tbotend"]], param_set[["tbotstart"]]), source.deme = c(0, 0),
      sink.deme = c(0, 0), new.sink.size = c(param_set[["nbot_prop"]], param_set[["nhist_bot_prop"]])
    )
  }
  
  # 2 is for neutral
  if (model == 0){
    hist_ev <- strataG::fscHistEv(
      num.gen = param_set[["tbotstart"]], source.deme = 0,
      sink.deme = 0, new.sink.size = param_set[["nhist_neut_prop"]]
    )
  }
  
  msat_params <- strataG::fscLocusParams(
    locus.type = "msat", num.loci = param_set[["num_loci"]], 
    mut.rate = param_set[["mut_rate"]], gsm.param = param_set[["gsm_param"]], 
    range.constraint = param_set[["range_constraint"]], ploidy = 2
  )
  
  sim_msats <- strataG::fastsimcoal(pop.info = pop_info, locus.params = msat_params, 
                                    hist.ev = hist_ev, exec = "/home/martin/bin/fsc25221", label = lab) # , 
  
  
  # calculate summary statistics
  
  # num_alleles, allel_richness, prop_unique_alleles, expt_het, obs_het
  # mean and sd
  num_alleles <- strataG::numAlleles(sim_msats)
  num_alleles_mean <- mean(num_alleles, na.rm = TRUE)
  num_alleles_sd <- sd(num_alleles, na.rm = TRUE)
  # exp_het
  exp_het <- strataG::exptdHet(sim_msats)
  exp_het_mean <- mean(exp_het, na.rm = TRUE)
  exp_het_sd <- sd(exp_het, na.rm = TRUE)
  # obs_het
  obs_het <- strataG::obsvdHet(sim_msats)
  obs_het_mean <- mean(obs_het, na.rm = TRUE)
  obs_het_sd <- sd(obs_het, na.rm = TRUE)
  # mratio mean and sd
  mratio <- strataG::mRatio(sim_msats, by.strata = FALSE, rpt.size = 1)
  mratio_mean <- mean(mratio, na.rm = TRUE)
  mratio_sd <- stats::sd(mratio, na.rm = TRUE)
  # allele frequencies
  afs <- strataG::alleleFreqs(sim_msats)
  # prop low frequency alleles
  prop_low_af <- function(afs){
    # low_afs <- (afs[, "freq"] / sum(afs[, "freq"])) < 0.05
    low_afs <- afs[, "prop"] <= 0.05
    prop_low <- sum(low_afs) / length(low_afs)
  }
  # and mean/sd for all
  prop_low_afs <- unlist(lapply(afs, prop_low_af))
  prop_low_afs_mean <- mean(prop_low_afs, na.rm = TRUE)
  prop_low_afs_sd <- stats::sd(prop_low_afs, na.rm = TRUE)
  # allele range
  allele_range <- unlist(lapply(afs, function(x) diff(range(as.numeric(row.names(x))))))
  mean_allele_range <- mean(allele_range, na.rm = TRUE)
  sd_allele_range <- sd(allele_range, na.rm = TRUE)
  
  # allele size variance and kurtosis
  # create vector of all alleles per locus
  all_alleles <- function(afs_element){
    alleles <- as.numeric(rep(row.names(afs_element), as.numeric(afs_element[, "freq"])))
    size_sd <- stats::sd(alleles)
    size_kurtosis <- moments::kurtosis(alleles, na.rm = TRUE)
    out <- data.frame(size_sd = size_sd, size_kurtosis = size_kurtosis)
  }
  all_allele_size_ss <- do.call(rbind, lapply(afs, all_alleles))
  
  mean_allele_size_sd <- mean(all_allele_size_ss$size_sd, na.rm = TRUE)
  sd_allele_size_sd <- sd(all_allele_size_ss$size_sd, na.rm = TRUE)
  
  mean_allele_size_kurtosis <- mean(all_allele_size_ss$size_kurtosis, na.rm = TRUE)
  sd_allele_size_kurtosis <- sd(all_allele_size_ss$size_kurtosis, na.rm = TRUE)
  
  out <- data.frame(
    num_alleles_mean, num_alleles_sd,
    exp_het_mean, exp_het_sd,
    obs_het_mean, obs_het_sd,
    mean_allele_size_sd, sd_allele_size_sd,
    mean_allele_size_kurtosis, sd_allele_size_kurtosis,
    mean_allele_range, sd_allele_range,
    mratio_mean, mratio_sd,
    prop_low_afs_mean, prop_low_afs_sd
  )
}


# Run function on cluster with 40 cores
# cl <- makeCluster(getOption("cl.cores", 10))
# clusterEvalQ(cl, c(library("strataG")))
# 
# sims_all <- parApply(cl, all_params, 1, run_sims)
# sims_df <- as.data.frame(data.table::rbindlist(sims_all))
# 
# stopCluster(cl)

sims_all <- apply(all_params, 1, run_sims)
sims_df <- as.data.frame(data.table::rbindlist(sims_all))

# reshape data to get a clean data.frame
abc_post <- abc_pars %>% 
  select(species, post_mod)

sims <- cbind(as.data.frame(abc_post), sims_df, all_params)
# save simulations in a txt file
# original
# write.table(sims, file = "sims_10000k.txt", row.names = FALSE)
write.table(sims, file = "../abc_analysis/model_evaluation/check5_postpred/sims_10000kbot500_post_pred_checks1.txt", row.names = FALSE)


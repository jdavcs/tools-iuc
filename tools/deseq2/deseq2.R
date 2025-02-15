#!/usr/bin/env Rscript

# A command-line interface to DESeq2 for use with Galaxy
# written by Bjoern Gruening and modified by Michael Love 2016.03.30
#
# This argument is required:
#
#   'factors' a JSON list object from Galaxy
#
# the output file has columns:
#
#   baseMean (mean normalized count)
#   log2FoldChange (by default a moderated LFC estimate)
#   lfcSE (the standard error)
#   stat (the Wald statistic)
#   pvalue (p-value from comparison of Wald statistic to a standard Normal)
#   padj (adjusted p-value, Benjamini Hochberg correction on genes which pass the mean count filter)
#
# the first variable in 'factors' will be the primary factor.
# the levels of the primary factor are used in the order of appearance in factors.
#
# by default, levels in the order A,B,C produces a single comparison of B vs A, to a single file 'outfile'
#
# for the 'many_contrasts' flag, levels in the order A,B,C produces comparisons C vs A, B vs A, C vs B,
# to a number of files using the 'outfile' prefix: 'outfile.condition_C_vs_A' etc.
# all plots will still be sent to a single PDF, named by the arg 'plots', with extra pages.
#
# fit_type is an integer valued argument, with the options from ?estimateDisperions
#   1 "parametric"
#   2 "local"
#   3 "mean"

# setup R error handling to go to stderr
options( show.error.messages=F, error = function () { cat( geterrmessage(), file=stderr() ); q( "no", 1, F ) } )

# we need that to not crash galaxy with an UTF8 error on German LC settings.
loc <- Sys.setlocale("LC_MESSAGES", "en_US.UTF-8")

library("getopt")
library("tools")
options(stringAsFactors = FALSE, useFancyQuotes = FALSE)
args <- commandArgs(trailingOnly = TRUE)

# get options, using the spec as defined by the enclosed list.
# we read the options from the default: commandArgs(TRUE).
spec <- matrix(c(
  "quiet", "q", 0, "logical",
  "help", "h", 0, "logical",
  "cores", "s", 0, "integer",
  "batch_factors", "w", 1, "character",
  "outfile", "o", 1, "character",
  "countsfile", "n", 1, "character",
  "rlogfile", "r", 1, "character",
  "vstfile", "v", 1, "character",
  "header", "H", 0, "logical",
  "factors", "f", 1, "character",
  "files_to_labels", "l", 1, "character",
  "plots" , "p", 1, "character",
  "tximport", "i", 0, "logical",
  "txtype", "y", 1, "character",
  "tx2gene", "x", 1, "character", # a space-sep tx-to-gene map or GTF/GFF3 file
  "esf", "e", 1, "character",
  "fit_type", "t", 1, "integer",
  "many_contrasts", "m", 0, "logical",
  "outlier_replace_off" , "a", 0, "logical",
  "outlier_filter_off" , "b", 0, "logical",
  "auto_mean_filter_off", "c", 0, "logical",
  "beta_prior_off", "d", 0, "logical"),
  byrow=TRUE, ncol=4)
opt <- getopt(spec)

# if help was asked for print a friendly message
# and exit with a non-zero error code
if (!is.null(opt$help)) {
  cat(getopt(spec, usage=TRUE))
  q(status=1)
}

# enforce the following required arguments
if (is.null(opt$outfile)) {
  cat("'outfile' is required\n")
  q(status=1)
}
if (is.null(opt$factors)) {
  cat("'factors' is required\n")
  q(status=1)
}

verbose <- if (is.null(opt$quiet)) {
  TRUE
} else {
  FALSE
}

source_local <- function(fname){
    argv <- commandArgs(trailingOnly = FALSE)
    base_dir <- dirname(substring(argv[grep("--file=", argv)], 8))
    source(paste(base_dir, fname, sep="/"))
}

source_local('get_deseq_dataset.R')

suppressPackageStartupMessages({
  library("DESeq2")
  library("RColorBrewer")
  library("gplots")
})

if (opt$cores > 1) {
  library("BiocParallel")
  register(MulticoreParam(opt$cores))
  parallel = TRUE
} else {
  parallel = FALSE
}

# build or read sample table

trim <- function (x) gsub("^\\s+|\\s+$", "", x)

# switch on if 'factors' was provided:
library("rjson")
parser <- newJSONParser()
parser$addData(opt$factors)
factorList <- parser$getObject()
filenames_to_labels <- fromJSON(opt$files_to_labels)
factors <- sapply(factorList, function(x) x[[1]])
primaryFactor <- factors[1]
filenamesIn <- unname(unlist(factorList[[1]][[2]]))
labs = unname(unlist(filenames_to_labels[basename(filenamesIn)]))
sampleTable <- data.frame(sample=basename(filenamesIn),
                          filename=filenamesIn,
                          row.names=filenamesIn,
                          stringsAsFactors=FALSE)
for (factor in factorList) {
  factorName <- trim(factor[[1]])
  sampleTable[[factorName]] <- character(nrow(sampleTable))
  lvls <- sapply(factor[[2]], function(x) names(x))
  for (i in seq_along(factor[[2]])) {
    files <- factor[[2]][[i]][[1]]
    sampleTable[files,factorName] <- trim(lvls[i])
  }
  sampleTable[[factorName]] <- factor(sampleTable[[factorName]], levels=lvls)
}
rownames(sampleTable) <- labs

primaryFactor <- factors[1]
designFormula <- as.formula(paste("~", paste(rev(factors), collapse=" + ")))

# these are plots which are made once for each analysis
generateGenericPlots <- function(dds, factors) {
  library("ggplot2")
  library("ggrepel")
  library("pheatmap")

  rld <- rlog(dds)
  p <- plotPCA(rld, intgroup=rev(factors))
  print(p + geom_text_repel(aes_string(x = "PC1", y = "PC2", label = factor(colnames(dds))), size=3)  + geom_point())
  dat <- assay(rld)
  distsRL <- dist(t(dat))
  mat <- as.matrix(distsRL)
  colors <- colorRampPalette( rev(brewer.pal(9, "Blues")) )(255)
  pheatmap(mat,
           clustering_distance_rows=distsRL,
           clustering_distance_cols=distsRL,
           col=colors,
           main="Sample-to-sample distances")
  plotDispEsts(dds, main="Dispersion estimates")
}

# these are plots which can be made for each comparison, e.g.
# once for C vs A and once for B vs A
generateSpecificPlots <- function(res, threshold, title_suffix) {
  use <- res$baseMean > threshold
  if (sum(!use) == 0) {
    h <- hist(res$pvalue, breaks=0:50/50, plot=FALSE)
    barplot(height = h$counts,
            col = "powderblue", space = 0, xlab="p-values", ylab="frequency",
            main=paste("Histogram of p-values for",title_suffix))
    text(x = c(0, length(h$counts)), y = 0, label=paste(c(0,1)), adj=c(0.5,1.7), xpd=NA)
  } else {
    h1 <- hist(res$pvalue[!use], breaks=0:50/50, plot=FALSE)
    h2 <- hist(res$pvalue[use], breaks=0:50/50, plot=FALSE)
    colori <- c("filtered (low count)"="khaki", "not filtered"="powderblue")
    barplot(height = rbind(h1$counts, h2$counts), beside = FALSE,
            col = colori, space = 0, xlab="p-values", ylab="frequency",
            main=paste("Histogram of p-values for",title_suffix))
    text(x = c(0, length(h1$counts)), y = 0, label=paste(c(0,1)), adj=c(0.5,1.7), xpd=NA)
    legend("topright", fill=rev(colori), legend=rev(names(colori)), bg="white")
  }
    plotMA(res, main= paste("MA-plot for",title_suffix), ylim=range(res$log2FoldChange, na.rm=TRUE))
}

if (verbose) {
  cat(paste("primary factor:",primaryFactor,"\n"))
  if (length(factors) > 1) {
    cat(paste("other factors in design:",paste(factors[-length(factors)],collapse=","),"\n"))
  }
  cat("\n---------------------\n")
}

dds <- get_deseq_dataset(sampleTable, header=opt$header, designFormula=designFormula, tximport=opt$tximport, txtype=opt$txtype, tx2gene=opt$tx2gene)
# estimate size factors for the chosen method
if(!is.null(opt$esf)){
    dds <- estimateSizeFactors(dds, type=opt$esf)
}
apply_batch_factors <- function (dds, batch_factors) {
  rownames(batch_factors) <- batch_factors$identifier
  batch_factors <- subset(batch_factors, select = -c(identifier, condition))
  dds_samples <- colnames(dds)
  batch_samples <- rownames(batch_factors)
  if (!setequal(batch_samples, dds_samples)) {
    stop("Batch factor names don't correspond to input sample names, check input files")
  }
  dds_data <- colData(dds)
  # Merge dds_data with batch_factors using indexes, which are sample names
  # Set sort to False, which maintains the order in dds_data
  reordered_batch <- merge(dds_data, batch_factors, by.x = 0, by.y = 0, sort=F)
  batch_factors <- reordered_batch[, ncol(dds_data):ncol(reordered_batch)]
  for (factor in colnames(batch_factors)) {
    dds[[factor]] <- batch_factors[[factor]]
  }
  colnames(dds) <- reordered_batch[,1]
  return(dds)
}

if (!is.null(opt$batch_factors)) {
  batch_factors <- read.table(opt$batch_factors, sep="\t", header=T)
  dds <- apply_batch_factors(dds = dds, batch_factors = batch_factors)
  batch_design <- colnames(batch_factors)[-c(1,2)]
  designFormula <- as.formula(paste("~", paste(c(batch_design, rev(factors)), collapse=" + ")))
  design(dds) <- designFormula
}

if (verbose) {
  cat("DESeq2 run information\n\n")
  cat("sample table:\n")
  print(sampleTable[,-c(1:2),drop=FALSE])
  cat("\ndesign formula:\n")
  print(designFormula)
  cat("\n\n")
  cat(paste(ncol(dds), "samples with counts over", nrow(dds), "genes\n"))
}

# optional outlier behavior
if (is.null(opt$outlier_replace_off)) {
  minRep <- 7
} else {
  minRep <- Inf
  if (verbose) cat("outlier replacement off\n")
}
if (is.null(opt$outlier_filter_off)) {
  cooksCutoff <- TRUE
} else {
  cooksCutoff <- FALSE
  if (verbose) cat("outlier filtering off\n")
}

# optional automatic mean filtering
if (is.null(opt$auto_mean_filter_off)) {
  independentFiltering <- TRUE
} else {
  independentFiltering <- FALSE
  if (verbose) cat("automatic filtering on the mean off\n")
}

# shrinkage of LFCs
if (is.null(opt$beta_prior_off)) {
  betaPrior <- TRUE
} else {
  betaPrior <- FALSE
  if (verbose) cat("beta prior off\n")
}

# dispersion fit type
if (is.null(opt$fit_type)) {
  fitType <- "parametric"
} else {
  fitType <- c("parametric","local","mean")[opt$fit_type]
}

if (verbose) cat(paste("using disperion fit type:",fitType,"\n"))

# run the analysis
dds <- DESeq(dds, fitType=fitType, betaPrior=betaPrior, minReplicatesForReplace=minRep, parallel=parallel)

# create the generic plots and leave the device open
if (!is.null(opt$plots)) {
  if (verbose) cat("creating plots\n")
  pdf(opt$plots)
  generateGenericPlots(dds, factors)
}

n <- nlevels(colData(dds)[[primaryFactor]])
allLevels <- levels(colData(dds)[[primaryFactor]])

if (!is.null(opt$countsfile)) {
    normalizedCounts<-counts(dds,normalized=TRUE)
    write.table(normalizedCounts, file=opt$countsfile, sep="\t", col.names=NA, quote=FALSE)
}

if (!is.null(opt$rlogfile)) {
    rLogNormalized <-rlogTransformation(dds)
    rLogNormalizedMat <- assay(rLogNormalized)
    write.table(rLogNormalizedMat, file=opt$rlogfile, sep="\t", col.names=NA, quote=FALSE)
}

if (!is.null(opt$vstfile)) {
    vstNormalized<-varianceStabilizingTransformation(dds)
    vstNormalizedMat <- assay(vstNormalized)
    write.table(vstNormalizedMat, file=opt$vstfile, sep="\t", col.names=NA, quote=FALSE)
}


if (is.null(opt$many_contrasts)) {
  # only contrast the first and second level of the primary factor
  ref <- allLevels[1]
  lvl <- allLevels[2]
  res <- results(dds, contrast=c(primaryFactor, lvl, ref),
                 cooksCutoff=cooksCutoff,
                 independentFiltering=independentFiltering)
  if (verbose) {
    cat("summary of results\n")
    cat(paste0(primaryFactor,": ",lvl," vs ",ref,"\n"))
    print(summary(res))
  }
  resSorted <- res[order(res$padj),]
  outDF <- as.data.frame(resSorted)
  outDF$geneID <- rownames(outDF)
  outDF <- outDF[,c("geneID", "baseMean", "log2FoldChange", "lfcSE", "stat", "pvalue", "padj")]
  filename <- opt$outfile
  write.table(outDF, file=filename, sep="\t", quote=FALSE, row.names=FALSE, col.names=FALSE)
  if (independentFiltering) {
    threshold <- unname(attr(res, "filterThreshold"))
  } else {
    threshold <- 0
  }
  title_suffix <- paste0(primaryFactor,": ",lvl," vs ",ref)
  if (!is.null(opt$plots)) {
    generateSpecificPlots(res, threshold, title_suffix)
  }
} else {
  # rotate through the possible contrasts of the primary factor
  # write out a sorted table of results with the contrast as a suffix
  # add contrast specific plots to the device
  for (i in seq_len(n-1)) {
    ref <- allLevels[i]
    contrastLevels <- allLevels[(i+1):n]
    for (lvl in contrastLevels) {
      res <- results(dds, contrast=c(primaryFactor, lvl, ref),
                     cooksCutoff=cooksCutoff,
                     independentFiltering=independentFiltering)
      resSorted <- res[order(res$padj),]
      outDF <- as.data.frame(resSorted)
      outDF$geneID <- rownames(outDF)
      outDF <- outDF[,c("geneID", "baseMean", "log2FoldChange", "lfcSE", "stat", "pvalue", "padj")]
      filename <- paste0(primaryFactor,"_",lvl,"_vs_",ref)
      write.table(outDF, file=filename, sep="\t", quote=FALSE, row.names=FALSE, col.names=FALSE)
      if (independentFiltering) {
        threshold <- unname(attr(res, "filterThreshold"))
      } else {
        threshold <- 0
      }
      title_suffix <- paste0(primaryFactor,": ",lvl," vs ",ref)
      if (!is.null(opt$plots)) {
        generateSpecificPlots(res, threshold, title_suffix)
      }
    }
  }
}

# close the plot device
if (!is.null(opt$plots)) {
  cat("closing plot device\n")
  dev.off()
}

cat("Session information:\n\n")

sessionInfo()


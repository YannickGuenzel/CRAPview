# CRAPview

MATLAB pipeline for processing PrairieView two-photon calcium imaging data. Supports single-plane and volumetric recordings, with batch processing across animals and trials.

## Features

- Loads channel-specific TIFF data and acquisition timestamps from PrairieView XML files.
- Performs optional NoRMCorre motion correction, spatial/temporal filtering, and maximum-intensity projection.
- Segments ROIs using CalciSeg or interactive manual slicing, with shared or trial-specific segmentation.
- Calculates region-averaged fluorescence and ΔF/F using a baseline window or quantile.
- Exports processed data, ROI traces, timing information, videos, and summary figures.

## Requirements

- MATLAB (the script header specifies R2024a), Image Processing Toolbox, and Parallel Computing Toolbox.
- [NoRMCorre](https://github.com/flatironinstitute/CaImAn-MATLAB), [BrewerMap](https://github.com/DrosteEffect/BrewerMap), [CalciSeg](https://github.com/YannickGuenzel/CalciSeg), and [export_fig](https://github.com/altmany/export_fig), including their dependencies.
- A graphics-capable MATLAB session with MPEG-4 export support.

Place the external packages under the folder specified by `SET.GithubPath`, using the subfolder names `NoRMCorre`, `BrewerMap`, `CalciSeg`, and `export_fig`, or adjust the script's `addpath` calls.

## Input layout

Select a condition folder containing animal folders. Animal folder names must contain `Animal`; trial folder names must contain `TSeries`.

```text
CONDITION/
  Animal01/
    01_Data_raw/
      TSeries-example-001/
        TSeries-example-001.xml
        <channel-specific TIFF files>
      TSeries-example-002/
        ...
  Animal02/
    ...
```

## Outputs

Each animal's `02_Data_Processed` folder contains MATLAB results (`results.mat`), HDF5 stacks, JSON metadata, per-trial/per-plane CSVs, MP4 previews, and PDF summaries. CSV exports include ROI labels, fluorescence, ΔF/F, baselines, and imaging times; voltage recordings are exported when available. `COMPLETE.json` marks a completed export.

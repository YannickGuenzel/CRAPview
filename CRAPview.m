%% CRAPview
% Process PrairieView two-photon imaging trials: load a selected channel
% and acquisition timestamps, optionally correct motion, filter images,
% identify usable frames, segment ROIs, and calculate pixel and region dF/F.
% Supports single-plane and volumetric recordings with shared or
% trial-specific segmentation.
%
% In the following, we lay out the folder structure needed for CRAPview to
% run without errors:
% DATA : top level folder
% > COND_A : this is the folder you select at the
% | beginning
% |--> Animal01 : this folder can have any name that
% | | contains the string "Animal"
% | |--> 01_Data_raw : CRAPview assumes this folder contains
% | | | the raw data, separated by trials
% | | |--> TSeries-*-001 : CRAPview assumes this folder contains an
% | | | xml-file with timing information
% | | | together with either a tiff stack (2D
% | | | data) or multiple stacks (3D data)
% | | |--> TSeries-*-### : same logic for all following trials
% | |--> 02_Data_Processed : created automatically by this script and
% | | | holds the preprocessed + segmented data
% |--> Animal## : same logic for all following animals
% > COND_B : same logic for all following conditions
%
% Ensure you have pulled the following external toolboxes from GitHub
% - https://github.com/flatironinstitute/CaImAn-MATLAB
% - https://github.com/DrosteEffect/BrewerMap
% - https://github.com/YannickGuenzel/CalciSeg
% - https://github.com/altmany/export_fig
%
% MATLAB R2024a

% Report processing warnings and record failures separately for each animal.
clear all; close all; clc
delete(gcp('nocreate'))
parpool("Threads");

%% Settings

% Imaging channel required in each selected TIFF filename (Ch2 = green).
SET.Channel = 'Ch2';

% Path to GitHub folder
SET.GithubPath = '...\GitHub\';

% Volumetric data with a piezo can result in the first plane being off.
% This setting allows you to remove it.
SET.dropTop = true;

% Set whether to process trials together. Alternatively, trial one can be
% used as an template. Or all trials are corrected separately.
SET.CorrectMotion_pool = 'together';                                       % 'together' or 'template' or 'separate'

% Affine motion registration before NoRMCorre.
SET.AffineCorrectMotion = false;
SET.Affine_iter = 10;
SET.Affine_maxIter = 250;
SET.Affine_tformType = 'affine';                                           % 'affine' or 'translation' or 'rigid" or 'similarity'

% Set whether to correct for motion using NoRMCorre with standard settings.
SET.NonrigidCorrectMotion = true;
% Set for how may iterations NoRMCorre should run
SET.NoRMCorre_iter = 3;
% More detailed settings for non-rigid motion correction. If the data are
% single-plane recordings, the third value will  be dropped automatically
SET.NoRMCorre_gridSize       = [32, 32, 4];
SET.NoRMCorre_overlap_pre    = [24, 24, 2];
SET.NoRMCorre_overlap_post   = [24, 24, 2];
SET.NoRMCorre_mot_uf         = [04, 04, 1];
SET.NoRMCorre_max_shift      = [24, 24, 2];
SET.NoRMCorre_max_dev        = [08, 08, 1];
SET.NoRMCorre_min_patch_size = [16, 16, 1];
% If the data is 3D, i.e., a volume over time, set whether the motion
% correction should be done per plane (2D) or applied to the whole volume
% at once (3D; this requires a lot of memory)
SET.NoRMCorre_dim = '2D';                                                  % '2D' or '3D'

% Set the standard deviation for 2D Gaussian filtering ('gauss'), box
% size for 2D median filtering ('med'), or both [box, std] for
% both ('med-gauss'), or vice versa for 'gauss-med'
SET.SmoothData_spat_type = 'med-gauss';                                    % 'med' or 'gauss' or 'med-gauss' or 'gauss-med'
SET.SmoothData_spat = [3 1];

% Set whether to apply temporal filtering and which method to use.
% Available approaches are: movmean, movmedian, or n-th order butterworth
% low-pass filter. For movmean or movmedian specify a window length in
% frames. For butterworth, specifiy filter order and cutt-off frequency in
% Hz (e.g., SET.SmoothData_temp = [4, 1] for a 4th order filter with a 1Hz
% cutt-off.
% Set SmoothData_temp_type=[]; to skip temporal smoothing
SET.SmoothData_temp_type = 'butter';                                       % 'movmean' or 'movmedian' or 'butter'
SET.SmoothData_temp = [4 0.4];

% Set the nth-degree polynomial trend to remove from each pixel's signal.
% Set SET.Detrend to 1 for a linear trend, 2 for a quadratic trend, or a
% higher integer for a higher-degree polynomial. Use 'log-n' to fit the
% polynomial to log-transformed data (e.g., 'log-1').
% Use 'exp2' to subtract a biexponential fit to the plane's median trace,
% followed by a linear detrend per pixel. Use 'hpf-0.02' for a 2nd-order
% high-pass filter with a cutoff of 0.02 Hz. Each trial is processed separately.
% To skip detrending, set SET.Detrend to 0.
SET.Detrend = 0;

% Set whether the individual planes of a volume should be compressed to a
% single plane using a maximum projection
SET.max_compression = false;
SET.max_compression_planes = 8;

% Set which segmentation approach to take. Choose CalciSeg for most
% imaging data and an unbiased approach. For now, it will operate on each
% plane individually. You can fine-tune its settings below. Alternatively,
% you can segment the central complex upper and lower units into N euqally
% spaced segments. For this, use 'manualSliceSeg'.
% Set SET.segmentation_method=[] to skip segmentation
SET.segmentation_method = 'CalciSeg';                                      % 'CalciSeg' or 'manualSliceSeg'

% To calculate dFF, we can either use a fixed window as the baseline or use
% a quantile over the whole recording. For the window, set the beginning
% and the end frame, i.e., SET.dFF_value=[start stop]. For the quantile,
% just the quantile, e.g., SET.dFF_value=0.05.
SET.dFF_type = 'window';                                                   % 'window', 'quantile' or 'trigger'
SET.dFF_value = [5 20];

%% More detailed settings

% Frame QC. Enter the detector clipping level in stored TIFF units for
% systems whose ADC range is narrower than the TIFF integer class.
SET.SaturationLevel = [];          % Empty uses the integer TIFF storage ceiling.
SET.MaxSaturatedFraction = 0.01;
SET.FlashMAD = 8;                  % Robust brightness outlier threshold, for review.
SET.ExcludeBrightFrames = false;   % Enable only for acquisitions with known flash artifacts.
SET.ExcludeFrames = struct();      % E.g. SET.ExcludeFrames.TSeries_001 = [12 13];
SET.GapFactor = 1.5;               % Split temporal processing at long frame intervals.
SET.MaxMotionPx = Inf;             % Maximum registration displacement in pixels/voxels.
SET.MinReferenceCorrelation = -1; % Raise to exclude poorly aligned frames.
SET.AxialCorrelationMargin = 0.05; % Neighboring plane preference flags frames for review.

% For 'trigger', set dFF_value to [start end] in seconds from the selected
% edge. Offset converts voltage recording seconds to imaging relative time.
SET.TriggerEdge = 'rising';        % 'rising' or 'falling'
SET.TriggerIndex = 1;
SET.VoltageTimeOffset = 0;
SET.MinBaseline = 0;               % Minimum usable absolute F0, in fluorescence units.
SET.MinBaselineFraction = 0.01;    % Also flag F0 below 1% of the typical plane F0.
SET.MinBaselineFrames = 1;

% Embed each acquired frame using segmented dF/F traces pooled across trials.
SET.FramePCA = true;

% Set colors
SET.colmap = 'RdBu';      % BrewerMap
SET.TrialColors = 'Set2'; % MATLAB color order (SET.TrialColors=[];), or a BrewerMap name such as 'Set2'.

% Record the seed used at the segmentation call for each animal.
SET.RandomSeed = 1;

% Set whether to re-run already processed data
SET.overwrite = true;

%% CalciSeg segmentation settings

SET.segmentation_settings = struct();
if strcmp(SET.segmentation_method, 'CalciSeg')
    % Choose custom CalciSeg setting here. See its documentation for
    % details.
    SET.segmentation_settings.quiet = false;
    SET.segmentation_settings.projection_method = 'std';
    SET.segmentation_settings.init_seg_method = 'rICA';
    SET.segmentation_settings.detrend = 'dff';
    SET.segmentation_settings.n_PCA = 99;
    SET.segmentation_settings.n_rep = 5;
    SET.segmentation_settings.refinement_method = 'rmse';
    SET.segmentation_settings.limitPixCount = [9 inf];
    SET.segmentation_settings.corr_thresh = 0.975;
    SET.segmentation_settings.fillmissing = true;
    SET.segmentation_settings.pool_fragments = true;

elseif strcmp(SET.segmentation_method, 'manualSliceSeg')
    % Choose custom manualSliceSeg setting here. See its documentation for
    % details.
    SET.segmentation_settings.NumberOfROIs = 2;
    SET.segmentation_settings.SlicesPerROI = 9;
    SET.segmentation_settings.ROINames = {'CBU'; 'CBL'};

end%if CalciSeg

%% Prepare

% Link external toolboxes
% --- https://github.com/flatironinstitute/CaImAn-MATLAB
addpath(genpath([SET.GithubPath, 'NoRMCorre']))
% --- https://github.com/DrosteEffect/BrewerMap
addpath(genpath([SET.GithubPath, 'BrewerMap']))
% --- https://github.com/YannickGuenzel/CalciSeg
addpath(genpath([SET.GithubPath, 'CalciSeg']))
% --- https://github.com/altmany/export_fig
addpath(genpath([SET.GithubPath, 'export_fig']))

% Check QC thresholds before starting a batch. Trigger times are expressed
% relative to imaging start after applying the configured clock offset.
validateattributes(SET.MaxSaturatedFraction,{'numeric'},{'scalar','real','>=',0,'<=',1});
if ~isempty(SET.SaturationLevel)
    validateattributes(SET.SaturationLevel,{'numeric'},{'scalar','real','finite','positive'});
end
validateattributes(SET.MaxMotionPx,{'numeric'},{'scalar','real','nonnegative','nonnan'});
validateattributes(SET.MinReferenceCorrelation,{'numeric'},{'scalar','>=',-1,'<=',1});
validateattributes(SET.AxialCorrelationMargin,{'numeric'},{'scalar','finite','nonnegative'});
validateattributes(SET.GapFactor,{'numeric'},{'scalar','finite','>',1});
validateattributes(SET.FlashMAD,{'numeric'},{'scalar','positive','finite'});
validateattributes(SET.TriggerIndex,{'numeric'},{'scalar','positive','integer'});
SET.TriggerEdge = validatestring(SET.TriggerEdge,{'rising','falling'});
validateattributes(SET.VoltageTimeOffset,{'numeric'},{'scalar','real','finite'});
validateattributes(SET.MinBaseline,{'numeric'},{'scalar','real','finite','nonnegative'});
validateattributes(SET.MinBaselineFraction,{'numeric'},{'scalar','real','finite','>=',0,'<=',1});
validateattributes(SET.MinBaselineFrames,{'numeric'},{'scalar','positive','integer'});

% Record external toolbox entry points once per batch.
SET.codeFiles = struct();
entries = {'normcorre_batch','CalciSeg','brewermap','export_fig'};
for k = 1:numel(entries)
    filename = which(entries{k});
    if ~isempty(filename) && isfile(filename)
        SET.codeFiles.(entries{k}) = struct('path',filename,'sha256',sourceDigest(filename), ...
            'git_revision',gitRevision(fileparts(filename)));
    end
end

% Set a nice colormap for saving
SET.colmap = brewermap(1000, SET.colmap);

%% Process data

% Get the path to raw data
SET.path2animal = uigetdir(pwd, 'Select folder listing all animals');
% Handle cancellation
if isequal(SET.path2animal, 0)
    disp('Folder selection cancelled. Aborting.')
    return
end%if folder

% Get an overview of animal folders
curr.dir.all = dir(SET.path2animal);
% Keep a per-run summary beside the animal folders. Reset trial-specific
% settings between animals, including after an interrupted animal.
baseSettings = SET;
batch = table('Size',[0 4],'VariableTypes',repmat({'string'},1,4), ...
    'VariableNames',{'animal','status','stage','message'});
[~,runID] = fileparts(tempname);
batchFile = fullfile(SET.path2animal,['CRAPview_batch_' runID '.csv']);
assert(any(contains({curr.dir.all.name},'Animal') & [curr.dir.all.isdir]),'No animal folders found.');

% Iterate over all animals
for iAni = 1:size(curr.dir.all, 1)
    clearvars -except iAni curr baseSettings batch batchFile
    SET = baseSettings;
    % Check whether this is what we are looking for, i.e. whether the
    % string "Animal" is present
    if contains(curr.dir.all(iAni).name, 'Animal') && curr.dir.all(iAni).isdir
        % Process each animal in its own try/catch so one bad dataset only skips
        % that animal instead of aborting the whole batch.
        animal = curr.dir.all(iAni).name;
        status = "skipped";
        stage = "folder validation";
        message = "";
        try
            oneAnimal.dir.all = curr.dir.all(iAni);
            CheckFolderStructure(SET,oneAnimal);
            stage = "trial discovery";
            % Get information about trials
            curr.path.animal = fullfile(SET.path2animal, curr.dir.all(iAni).name, '01_Data_raw');
            curr.dir.animal = dir(curr.path.animal);
            SET.N = 0;
            SET.trial_names = cell(1);
            SET.trial_names_clean = cell(1);
            SET.VoltRec_names = cell(1);
            SET.VoltRec_names_clean = cell(1);
            for iItem = 1:size(curr.dir.animal, 1)
                if contains(curr.dir.animal(iItem).name, 'TSeries') && curr.dir.animal(iItem).isdir
                    SET.N = SET.N+1;
                    % Get information about TSeries data
                    SET.trial_names{SET.N} = curr.dir.animal(iItem).name;
                    SET.trial_names_clean{SET.N} = matlab.lang.makeValidName(SET.trial_names{SET.N});

                    % Check for accompanying voltage recording of trigger
                    % signals to external devices
                    if any(strcmp({curr.dir.animal.name}, ['VoltageRecording', SET.trial_names{SET.N}((length('TSeries')+1):end)]) & [curr.dir.animal.isdir])
                        SET.VoltRec_names{SET.N} = ['VoltageRecording', SET.trial_names{SET.N}((length('TSeries')+1):end)];
                        SET.VoltRec_names_clean{SET.N} = matlab.lang.makeValidName(SET.VoltRec_names{SET.N});
                    else
                        SET.VoltRec_names{SET.N} = [];
                        SET.VoltRec_names_clean{SET.N} = [];
                    end%if VoltageRecording
                end%if data
            end%iItem

            % ----- Load and process data -----
            % Check whether to run preprocessing or not
            if SET.overwrite || ~isfile(fullfile(SET.path2animal,animal,'02_Data_Processed','COMPLETE.json'))


                stage = "loading";
                QC = struct();
                % Load stacks
                % ---------------------------------------------------------
                for iTrial = 1:SET.N
                    % Get the folder content of the current trial
                    curr.path.(SET.trial_names_clean{iTrial}) = fullfile(SET.path2animal, curr.dir.all(iAni).name, '01_Data_raw', SET.trial_names{iTrial});
                    curr.dir.(SET.trial_names_clean{iTrial}) = dir(curr.path.(SET.trial_names_clean{iTrial}));

                    % Get xml file containing time points
                    curr.xml_name = [SET.trial_names{iTrial}, '.xml'];
                    curr.xml_path = fullfile(curr.path.(SET.trial_names_clean{iTrial}), curr.xml_name);

                    % Get frame times.
                    [SET.(SET.trial_names_clean{iTrial}).relativeTime, SET.(SET.trial_names_clean{iTrial}).absoluteTime] = readPrairieViewTimes(curr.xml_path);

                    % The output of readPrairieViewTimes will have multiple
                    % rows for 3D data. Use this to automatically determine
                    % the dimensionality of the data
                    SET.DataDimensionality = double(size(SET.(SET.trial_names_clean{iTrial}).relativeTime, 1) > 1) + 2;
                    % Also extract the number of plane and frames
                    SET.(SET.trial_names_clean{iTrial}).n_planes = size(SET.(SET.trial_names_clean{iTrial}).relativeTime, 1);
                    SET.(SET.trial_names_clean{iTrial}).n_frames = size(SET.(SET.trial_names_clean{iTrial}).relativeTime, 2);

                    % Get the current data
                    [STACK.(SET.trial_names_clean{iTrial}), SET] = getStack(SET, curr, iTrial);

                    % Drop first plane
                    if SET.dropTop && size(STACK.(SET.trial_names_clean{iTrial}), 3) > 1
                        STACK.(SET.trial_names_clean{iTrial}) = STACK.(SET.trial_names_clean{iTrial})(:, :, 2:end, :);
                        SET.(SET.trial_names_clean{iTrial}).relativeTime = SET.(SET.trial_names_clean{iTrial}).relativeTime(2:end, :);
                        SET.(SET.trial_names_clean{iTrial}).absoluteTime = SET.(SET.trial_names_clean{iTrial}).absoluteTime(2:end, :);
                        SET.(SET.trial_names_clean{iTrial}).n_planes = SET.(SET.trial_names_clean{iTrial}).n_planes - 1;
                    end%if drop first plane
                    SET.(SET.trial_names_clean{iTrial}).DataDimensionality = ...
                        2 + (size(STACK.(SET.trial_names_clean{iTrial}), 3) > 1);

                    % Every trial has a voltage entry, including absent recordings.
                    trialName = SET.trial_names_clean{iTrial};
                    voltage = struct('risingTime', [], 'fallingTime', []);
                    if ~isempty(SET.VoltRec_names{iTrial})
                        voltageName = SET.VoltRec_names_clean{iTrial};
                        voltageFolder = fullfile(curr.path.animal, SET.VoltRec_names{iTrial});
                        voltageFiles = dir(fullfile(voltageFolder, '*.csv'));
                        voltageFiles = voltageFiles(~[voltageFiles.isdir] & ...
                            contains({voltageFiles.name}, SET.VoltRec_names{iTrial}));
                        assert(numel(voltageFiles) == 1, ...
                            'Expected exactly one matching voltage CSV in %s.', voltageFolder);
                        voltageTable = readtable(fullfile(voltageFolder, voltageFiles(1).name));
                        voltageData = voltageTable{:, 1:2};
                        voltageData(:,1) = voltageData(:,1) / 1000; % ms to seconds
                        risingIndices = find(diff(voltageData(:,2)) > 0.5*max(voltageData(:,2))) + 1;
                        fallingIndices = find(diff(voltageData(:,2)) < -0.5*max(voltageData(:,2))) + 1;
                        voltage.risingTime = voltageData(risingIndices,1);
                        voltage.fallingTime = voltageData(fallingIndices,1);
                        SET.(voltageName) = voltage; % Retain the existing named-recording entry.
                    end
                    SET.(trialName).voltage = voltage;
                    QC.(trialName).sourcePlanes = (1:size(STACK.(trialName),3)) + ...
                        double(SET.dropTop && SET.DataDimensionality == 3);
                    % Prepare a mask
                    SET.STACK_mask.(SET.trial_names_clean{iTrial}) = ones(...
                        size(STACK.(SET.trial_names_clean{iTrial}),1), ...
                        size(STACK.(SET.trial_names_clean{iTrial}),2), ...
                        size(STACK.(SET.trial_names_clean{iTrial}),3))==1;
                end%iTrial

                % Compress planes before motion correction if we are
                % requesting only a single plane
                if SET.max_compression && isscalar(SET.max_compression_planes)
                    [STACK,SET] = compressPlanes(STACK, SET);
                    for k = 1:SET.N
                        name = SET.trial_names_clean{k};
                        QC.(name).sourcePlanes = QC.(name).sourcePlanes(SET.max_compression_planes);
                    end
                end

                % Keep the incoming fluorescence for direct before/after alignment scores.
                stage = "registration";
                unregistered = STACK;

                % Affine motion correction
                % ---------------------------------------------------------
                if SET.AffineCorrectMotion
                    [STACK,QC] = affinecorrectMotion(STACK, SET, QC);
                end


                % Non-rigid motion correction
                % ---------------------------------------------------------
                if SET.NonrigidCorrectMotion
                    [STACK,QC] = correctMotion(STACK, SET, QC);
                end%if correct motion


                % Score registration and identify frame gaps before temporal processing.
                stage = "frame QC";
                [QC,SET] = assessFrames(unregistered,STACK,QC,SET);
                clear unregistered

                % Prepare the detection and measurement movies separately. Process
                % each contiguous good run at its own plane's acquisition rate.
                stage = "filtering and detrending";
                [detection,STACK,QC] = prepareMovies(STACK,SET,QC);

                % Project the same planes in both branches and retain native-plane QC.
                if SET.max_compression && numel(SET.max_compression_planes)>1
                    [detection,~] = compressPlanes(detection,SET);
                    [STACK,SET] = compressPlanes(STACK,SET);
                    QC = projectQuality(QC,SET);
                    for k = 1:SET.N
                        name = SET.trial_names_clean{k};
                        bad = QC.(name).planes.frames.excluded;
                        STACK.(name)(:,:,:,bad) = NaN;
                    end
                end

                % Learn labels on detection frames and extract from the measurement movie.
                stage = "segmentation";
                rng(SET.RandomSeed,'twister');
                [STACK_proc, Segmentation] = segmentImages(detection, SET, STACK, QC);
                clear detection

                % Save measured region F and its actual F0 before normalizing either movie.
                stage = "baseline and normalization";
                [STACK,STACK_proc,Segmentation,QC,SET] = normalizeTrials(STACK,STACK_proc,Segmentation,QC,SET);

                % PCA embedding of frames across trials
                % ---------------------------------------------------------
                stage = "frame PCA";
                PCA = embedTrialFrames(Segmentation,SET,QC);
                if SET.FramePCA && ~strcmp(PCA.status,'complete')
                    warning('CRAPview:framePCA','Skipping PCA for %s: %s',animal,PCA.status);
                end

                stage = "export";
                % Store everything
                % ---------------------------------------------------------
                saveCRAPview(STACK, STACK_proc, Segmentation, SET,...
                    fullfile(SET.path2animal, curr.dir.all(iAni).name, '02_Data_Processed'),'Quality',QC,'FramePCA',PCA);
                status = "complete";
            else
                stage = "existing output";


            end%if overwrite
        catch ME
            status = "failed";
            message = string(ME.identifier) + " " + string(ME.message);
            warning('CRAPview:animalFailed', 'Skipping animal "%s": %s (%s)', ...
                curr.dir.all(iAni).name, ME.message, ME.identifier);
        end%try
        batch(end+1,:) = {string(animal),status,stage,message};
        writetable(batch,batchFile);
    end%if animal
end%iAni

% Point to the ledger even when a previous MATLAB session suppressed warnings.
fprintf('CRAPview: %d complete, %d skipped, %d failed. Batch summary: %s\n', ...
    nnz(batch.status=="complete"),nnz(batch.status=="skipped"),nnz(batch.status=="failed"),batchFile);

%% Subfunctions
%% ------------------------------------------------------------------------

function CheckFolderStructure(SET, curr)
msg = {};
% Iterate over all folders and check whether there is an animal folder
if any(contains({curr.dir.all.name}, 'Animal') & [curr.dir.all.isdir])
    for iAni = 1:size(curr.dir.all, 1)
        % Check whether the string "Animal" is present
        if ~isempty(strfind(curr.dir.all(iAni).name, 'Animal')) && curr.dir.all(iAni).isdir
            aniName = curr.dir.all(iAni).name;
            rawDir = fullfile(SET.path2animal, aniName, '01_Data_raw');
            % Check whether there is a raw data folder
            if isfolder(rawDir)
                % Get information about trials
                curr.dir.animal = dir(rawDir);
                % Check whether there is at least one trial
                if any(contains({curr.dir.animal.name}, 'TSeries') & [curr.dir.animal.isdir])
                    % Iterate over all trials
                    for iItem = 1:size(curr.dir.animal, 1)
                        if ~isempty(strfind(curr.dir.animal(iItem).name, 'TSeries')) && curr.dir.animal(iItem).isdir
                            trialName = curr.dir.animal(iItem).name;
                            trialDir = fullfile(rawDir, trialName);
                            curr.dir.trial = dir(trialDir);
                            % Check whether a xml file is available
                            if sum(contains({curr.dir.trial.name}, '.xml')) == 1
                                if any(strcmp({curr.dir.trial.name}, [trialName, '.xml']))
                                    % Check whether one or multiple tiff
                                    % files are availabke
                                    if ~any(contains({curr.dir.trial.name}, '.tif'))
                                        msg{end+1, 1} = [aniName, ' | No tif-file(s) found in ', trialName];
                                    end
                                else
                                    msg{end+1, 1} = [aniName, ' | The name of xml-file found in ', trialName, ' does not correspond to the folder name'];
                                end%xml file name
                            elseif sum(contains({curr.dir.trial.name}, '.xml')) > 1
                                msg{end+1, 1} = [aniName, ' | More than one xml-file found in ', trialName];
                            elseif sum(contains({curr.dir.trial.name}, '.xml')) == 0
                                msg{end+1, 1} = [aniName, ' | No xml-file found in ', trialName];
                            end%if xml file
                        end%if trial folder
                    end%iItem
                else
                    msg{end+1, 1} = [aniName, ' | No "TSeries-*-###" folder available.'];
                end%no trial folder
            else
                msg{end+1, 1} = [aniName, ' | No "01_Data_raw" folder available.'];
            end% no raw data
        end%if animal folder
    end%iAni
else
    msg{end+1, 1} = 'No animal folders available.';
end%if any animal folder
% Display error
if ~isempty(msg)
    combinedMsg = strjoin(msg, '\n');
    error(combinedMsg)
end%if error
end%FCN:CheckFolderStructure

%% ------------------------------------------------------------------------

function revision = gitRevision(folder)
% Ask Git for the installed checkout's revision when Git and a checkout
% are available. The entry-point digest also identifies uncommitted edits.
revision = '';
try
    args = java.util.ArrayList();
    for arg = {'git','-C',folder,'rev-parse','--verify','HEAD'}
        args.add(java.lang.String(arg{1}));
    end
    builder = java.lang.ProcessBuilder(args);
    builder.redirectErrorStream(true);
    process = builder.start();
    reader = java.io.BufferedReader(java.io.InputStreamReader(process.getInputStream()));
    cleanup = onCleanup(@() reader.close()); %#ok<NASGU>
    line = reader.readLine();
    if process.waitFor()==0 && ~isempty(line), revision = char(line); end
catch
    % Exported toolbox releases may have no Git executable or repository.
end
end

function digest = sourceDigest(filename)
% Hash the actual source bytes so local edits can be distinguished.
fid = fopen(filename,'rb');
assert(fid>=0,'Could not read %s.',filename);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
md = java.security.MessageDigest.getInstance('SHA-256');
md.update(fread(fid,Inf,'*int8'));
digest = lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2)',1,[]));
end

function [QC,SET] = assessFrames(raw,registered,QC,SET)
% Use one fixed image per plane for comparable before/after correlations.
for k = 1:SET.N
    name = SET.trial_names_clean{k};
    input = raw.(name);
    movie = registered.(name);
    if isfield(QC.(name),'validMask')
        SET.STACK_mask.(name) = SET.STACK_mask.(name) & QC.(name).validMask;
    end
    masks = SET.STACK_mask.(name);
    refs = median(movie,4,'omitnan');
    for z = 1:size(movie,3)
        mask = masks(:,:,z);
        % A Z translation can leave an outer plane with no common support.
        % Preserve its timing and mark all of its frames as unavailable.
        % Retain native frame numbers and timing, including long intervals.
        times = SET.(name).relativeTime(z,:)';
        dt = [NaN; diff(times)];
        assert(all(isfinite(times)) && all(dt(2:end)>0),'Invalid acquisition times in %s.',name);
        gap = dt > SET.GapFactor * median(dt,'omitnan');
        n = numel(times);
        affine = zeros(n,1);
        nonrigid = zeros(n,1);
        if isfield(QC.(name),'registration')
            r = QC.(name).registration(z);
            if isfield(r,'affineDisplacement'), affine = r.affineDisplacement; end
            if isfield(r,'nonrigidDisplacement'), nonrigid = r.nonrigidDisplacement; end
        end

        % Score raw clipping, whole-field brightness, registration and possible
        % out-of-plane displacement. Neighbor preference is a review flag.
        saturated = zeros(n,1);
        brightness = nan(n,1);
        before = nan(n,1);
        after = nan(n,1);
        axial = false(n,1);
        for f = 1:n
            image = input(:,:,z,f);
            saturated(f) = nnz(image >= SET.(name).saturationLevel)/numel(image);
            brightness(f) = median(image(:),'omitnan');
            aligned = movie(:,:,z,f);
            before(f) = imageCorrelation(image,refs(:,:,z),mask);
            after(f) = imageCorrelation(aligned,refs(:,:,z),mask);
            for neighbor = intersect([z-1 z+1],1:size(movie,3))
                common = mask & masks(:,:,neighbor);
                own = imageCorrelation(aligned,refs(:,:,z),common);
                other = imageCorrelation(aligned,refs(:,:,neighbor),common);
                axial(f) = axial(f) || other > own + SET.AxialCorrelationMargin;
            end
        end
        % Flag unusually bright frames for review. Trigger proximity alone
        % does not exclude a response. Explicit frame overrides are per trial.
        center = median(brightness,'omitnan');
        spread = median(abs(brightness-center),'omitnan');
        flash = brightness > center + SET.FlashMAD * max(1.4826*spread,eps(max(1,abs(center))));
        reason = strings(n,1);
        reason(saturated > SET.MaxSaturatedFraction) = "saturation ";
        if SET.ExcludeBrightFrames, reason(flash) = reason(flash) + "flash "; end
        motion = max(affine,nonrigid);
        badMotion = motion > SET.MaxMotionPx | after < SET.MinReferenceCorrelation;
        reason(badMotion) = reason(badMotion) + "motion ";
        if ~any(mask(:)), reason(:) = reason(:) + "no_support "; end
        if isfield(SET.ExcludeFrames,name)
            excludedFrames = SET.ExcludeFrames.(name);
            validateattributes(excludedFrames,{'numeric'},{'integer','positive','<=',n});
            reason(excludedFrames) = reason(excludedFrames) + "manual ";
        end
        edges = SET.(name).voltage.([SET.TriggerEdge 'Time']) + SET.VoltageTimeOffset;
        trigger = NaN;
        if numel(edges)>=SET.TriggerIndex, trigger = edges(SET.TriggerIndex); end
        Q = table((1:n)',times,SET.(name).absoluteTime(z,:)',dt,gap,saturated,brightness,flash, ...
            affine,nonrigid,motion,before,after,axial,times-trigger,strlength(reason)>0,strtrim(reason), ...
            'VariableNames',{'frame','time_s','absolute_time_s','interval_s','gap_before','saturated_fraction', ...
            'median_intensity','bright_frame_review','affine_max_corner_px','nonrigid_max_patch_voxels', ...
            'motion_score','corr_before','corr_after','axial_drift_review','trigger_relative_s','excluded','reason'});
        QC.(name).planes(z).frames = Q;
        QC.(name).planes(z).reference = refs(:,:,z);
        good = ~Q.excluded;
        if ~any(good)
            warning('CRAPview:noGoodFrames','No usable frames in %s plane %d.',name,z);
        end
        if any(good)
            meanImage = mean(movie(:,:,z,good),4,'omitnan');
        else
            meanImage = nan(size(mask));
        end
        meanImage(~mask) = NaN;
        QC.(name).planes(z).meanImage = meanImage;
    end
    % Retain the mean of the registered maximum projection for slice QC.
    if SET.max_compression && numel(SET.max_compression_planes)>1
        planes = reshape(SET.max_compression_planes,1,[]);
        good = true(1,size(movie,4));
        for z = planes, good = good & ~QC.(name).planes(z).frames.excluded'; end
        if any(good)
            projected = max(movie(:,:,planes,good),[],3);
            QC.(name).projectedMean = mean(projected,4,'omitnan');
        else
            QC.(name).projectedMean = nan(size(movie,1),size(movie,2));
        end
        outside = ~all(masks(:,:,planes),3);
        QC.(name).projectedMean(outside) = NaN;
    end
end
end

function score = imageCorrelation(a,b,mask)
% Pearson correlation on common measured pixels. Flat images have no score.
mask = mask & isfinite(a) & isfinite(b);
x = a(mask); y = b(mask);
x = x-mean(x); y = y-mean(y);
score = NaN;
if numel(x)>=2
    denominator = norm(x)*norm(y);
    if denominator>0, score = dot(x,y)/denominator; end
end
end

function [detection,measurement,QC] = prepareMovies(registered,SET,QC)
% Filter contiguous runs independently. Keep excluded acquisition slots as NaN.
detection = registered;
measurement = registered;
for k = 1:SET.N
    name = SET.trial_names_clean{k};
    for z = 1:size(registered.(name),3)
        q = QC.(name).planes(z).frames;
        mask = SET.STACK_mask.(name)(:,:,z);
        good = ~q.excluded;
        first = find(good & ([true; ~good(1:end-1)] | q.gap_before));
        last = find(good & ([~good(2:end); true] | [q.gap_before(2:end);false]));
        q.short_run_operations = strings(height(q),1);
        % A long acquisition interval splits runs at the first following frame.
        % A rejected acquisition slot splits them on both sides.
        % Extend measured borders for spatial smoothing only. Invalid pixels
        % are removed again before detection and measurement.
        [~,nearest] = bwdist(mask);
        det = nan(size(registered.(name),1),size(registered.(name),2),1,height(q));
        meas = det;
        for run = 1:numel(first)
            frames = first(run):last(run);
            original = registered.(name)(:,:,z,frames);
            local = SET;
            local.N = 1;
            local.trial_names_clean = {name};
            local.(name).relativeTime = q.time_s(frames)';
            local.STACK_mask.(name) = mask;
            % Reuse the pipeline filters. Too-short runs retain their samples
            % and record exactly which requested operations could not be fit.
            [local,note] = shortRunSettings(local,numel(frames));
            q.short_run_operations(frames) = note;
            padded = reshape(original,[],numel(frames));
            padded(~mask(:),:) = padded(nearest(~mask),:);
            part.(name) = reshape(padded,size(original));
            part = filterImages(part,local);
            part = detrendMovies(part,local);
            det(:,:,1,frames) = part.(name);

            % Apply the same temporal filter and detrend to registered fluorescence.
            part.(name) = reshape(padded,size(original));
            local.SmoothData_spat_type = [];
            part = filterImages(part,local);
            part = detrendMovies(part,local);
            meas(:,:,1,frames) = part.(name);
        end
        det = reshape(det,[],height(q));
        meas = reshape(meas,[],height(q));
        det(~mask(:),:) = 0;
        meas(~mask(:),:) = NaN;
        detection.(name)(:,:,z,:) = reshape(det,size(registered.(name),1),[],1,height(q));
        measurement.(name)(:,:,z,:) = reshape(meas,size(registered.(name),1),[],1,height(q));
        QC.(name).planes(z).frames = q;
    end
end
end

function [S,note] = shortRunSettings(S,n)
% filtfilt requires more than three filter orders. Polynomial fits require
% more samples than the degree, and biexponential fitting needs four samples.
note = "";
if strcmp(S.SmoothData_temp_type,'butter') && n <= 3*S.SmoothData_temp(1)
    S.SmoothData_temp_type = [];
    note = "lowpass ";
end
setting = S.Detrend;
if isnumeric(setting)
    tooShort = setting>0 && n<=setting;
elseif startsWith(setting,'log-')
    tooShort = n<=str2double(extractAfter(string(setting),'log-'));
elseif startsWith(setting,'hpf-')
    tooShort = n<=6;
else
    tooShort = strcmp(setting,'exp2') && n<4;
end
if tooShort, S.Detrend = 0; note = note + "detrending"; end
note = strtrim(note);
end

function QC = projectQuality(QC,SET)
% Preserve native scores in results.mat and combine only selected planes.
for k = 1:SET.N
    name = SET.trial_names_clean{k};
    native = QC.(name).planes;
    QC.(name).nativePlanes = native;
    planes = reshape(SET.max_compression_planes,1,[]);
    q = native(planes(1)).frames;
    q.time_s = SET.(name).relativeTime(:);
    q.absolute_time_s = SET.(name).absoluteTime(:);
    q.interval_s = [NaN;diff(q.time_s)];
    delta = q.time_s - native(planes(1)).frames.time_s;
    q.trigger_relative_s = q.trigger_relative_s + delta;
    % Use worst-case quality across contributing planes. Keep native
    % brightness and per-plane measurements available in nativePlanes.
    for z = planes(2:end)
        b = native(z).frames;
        for col = ["excluded","gap_before","axial_drift_review","bright_frame_review"]
            q.(col) = q.(col) | b.(col);
        end
        for col = ["saturated_fraction","motion_score","affine_max_corner_px","nonrigid_max_patch_voxels","median_intensity"]
            q.(col) = max(q.(col),b.(col));
        end
        for col = ["corr_before","corr_after"], q.(col) = min(q.(col),b.(col)); end
        q.reason = strtrim(q.reason+" "+b.reason);
        q.short_run_operations = strtrim(q.short_run_operations+" "+b.short_run_operations);
    end
    QC.(name).planes = struct('frames',q,'reference',max(cat(3,native(planes).reference),[],3), ...
        'meanImage',QC.(name).projectedMean);
    QC.(name).projectedSourcePlanes = QC.(name).sourcePlanes(planes);

end
end

function [STACK,processed,seg,QC,SET] = normalizeTrials(STACK,processed,seg,QC,SET)
% Select baseline samples per plane. Retain the fluorescence and denominator
% used for each ROI before overwriting the two movie arrays with dF/F.
for k = 1:SET.N
    name = SET.trial_names_clean{k};
    value = SET.dFF_value;
    n = size(STACK.(name),4);
    fallback = false;
    switch SET.dFF_type
        case 'window'
            valid = isnumeric(value) && isreal(value) && numel(value)==2 && all(isfinite(value(:))) && ...
                all(value(:)==fix(value(:))) && value(1)>=1 && value(2)<=n && value(1)<=value(2);
            if ~valid
                fallback = true;
                value = [1 n];
                warning('CRAPview:baselineFallback','Using the whole trial for %s.',name);
            end
        case 'trigger'
            validateattributes(value,{'numeric'},{'real','finite','numel',2});
            assert(value(1)<=value(2),'Trigger baseline limits must be ordered.');
        case 'quantile'
            validateattributes(value,{'numeric'},{'scalar','real','>=',0,'<=',1});
        otherwise
            error('Unknown dFF_type: %s',SET.dFF_type);
    end
    SET.(name).dFF_value = value;
    SET.(name).baseline_fallback = fallback;
    for z = 1:size(STACK.(name),3)
        q = QC.(name).planes(z).frames;
        keep = ~q.excluded;
        if strcmp(SET.dFF_type,'window')
            keep = keep & q.frame>=value(1) & q.frame<=value(2);
        elseif strcmp(SET.dFF_type,'trigger')
            assert(any(isfinite(q.trigger_relative_s)),'Missing selected trigger for %s.',name);
            keep = keep & q.trigger_relative_s>=value(1) & q.trigger_relative_s<=value(2);
        end
        q.baseline_frame = keep;
        QC.(name).planes(z).frames = q;
        % Normalize pixels using only finite samples in the selected interval.
        mask = SET.STACK_mask.(name)(:,:,z);
        pixels = reshape(STACK.(name)(:,:,z,:),[],n);
        pixels(:,q.excluded) = NaN;
        [f0,~,usable,floorValue] = baselineValues(pixels,keep,SET);
        validMap = reshape(usable,size(mask)) & mask;
        QC.(name).planes(z).pixelBaselineValid = validMap;
        QC.(name).planes(z).pixelBaselineSummary = struct('valid',nnz(validMap), ...
            'invalid',nnz(mask & ~validMap),'minimum_abs_F0',floorValue,'candidate_frames',nnz(keep),'window_fallback',fallback);
        denom = abs(f0); denom(~usable) = NaN;
        dff = (pixels-f0)./denom;
        STACK.(name)(:,:,z,:) = reshape(dff,size(mask,1),size(mask,2),1,n);

        % Normalize each segmentation time course using its own fluorescence baseline.
        summary = seg.(name)(z).summary_stats;
        if isscalar(summary) && isfield(summary,'avgTCs')
            traces = summary.avgTCs;
            assert(size(traces,2)==n,'Segmentation frame count differs for %s plane %d.',name,z);
            traces(:,q.excluded) = NaN;
            [segF0,~,segUsable] = baselineValues(traces,keep,SET,floorValue);
            denominator = abs(segF0);
            denominator(~segUsable) = NaN;
            summary.avgTCs = (traces-segF0)./denominator;
            summary.avgTCs_F0 = segF0;
            seg.(name)(z).summary_stats = summary;
        end

        % Collect measured region means for normalization.
        labels = seg.(name)(z).pockets_labeled;
        ids = unique(labels(:));
        regionMovie = reshape(processed.(name)(:,:,z,:),[],n);
        regionMovie(:,q.excluded) = NaN;
        F = nan(numel(ids),n);
        measuredPixels = find(mask);
        [presentIDs,first] = unique(labels(measuredPixels));
        [~,rows] = ismember(presentIDs,ids);
        F(rows,:) = regionMovie(measuredPixels(first),:);
        % Broadcast each region's normalized trace only onto measured pixels.
        [f0,count,usable] = baselineValues(F,keep,SET,floorValue);
        denom = abs(f0); denom(~usable) = NaN;
        regionDff = (F-f0)./denom;
        [~,idx] = ismember(labels(:),ids);
        regionMovie = regionDff(idx,:);
        regionMovie(~mask(:),:) = NaN;
        processed.(name)(:,:,z,:) = reshape(regionMovie,size(mask,1),size(mask,2),1,n);
        QC.(name).planes(z).fluorescence = F;
        low = isfinite(f0) & abs(f0)<=floorValue;
        QC.(name).planes(z).baselines = table((1:numel(ids))',ids,f0,count,low,usable, ...
            repmat(fallback,numel(ids),1),repmat(floorValue,numel(ids),1),'VariableNames',{'trace_row','region_id','F0', ...
            'valid_baseline_frames','low_baseline','usable','window_fallback','minimum_abs_F0'});
    end
end
end

function [f0,count,usable,floorValue] = baselineValues(F,keep,SET,floorValue)
% Evaluate the requested estimator on finite samples and retain its denominator.
samples = F(:,keep);
samples(~isfinite(samples)) = NaN;
count = sum(isfinite(samples),2);
if isempty(samples)
    f0 = nan(size(F,1),1);
elseif strcmp(SET.dFF_type,'quantile')
    f0 = quantile(samples,SET.dFF_value,2);
else
    f0 = mean(samples,2,'omitnan');
end
% Use the same plane-specific floor for pixel and region baselines.
if nargin<4
    scale = abs(f0(isfinite(f0) & f0~=0 & count>=SET.MinBaselineFrames));
    floorValue = SET.MinBaseline;
    if ~isempty(scale), floorValue = max(floorValue,SET.MinBaselineFraction*median(scale)); end
end
usable = isfinite(f0) & abs(f0)>floorValue & count>=SET.MinBaselineFrames;
end

function writeSliceQC(q,labels,regions,dff,folder,trialName,plane,planeTitle,cmap)
% Link each anatomical slice and trace row with the same label and slice ID.
fig = figure('Visible','off','Color','w','Position',[100 100 1200 550]);
cleanup = onCleanup(@() deleteVideoFigure(fig)); %#ok<NASGU>
layout = tiledlayout(fig,1,2);
ax = nexttile(layout);
imagesc(ax,q.meanImage,symmetricLimits(q.meanImage)); axis(ax,'image'); axis(ax,'off'); colormap(ax,cmap);
hold(ax,'on');
drawRegionEdges(ax,regionEdges(labels));
rows = find(regions.region_id>0);
names = strings(numel(rows),1);
for j = 1:numel(rows)
    i = rows(j);
    roi = labels==regions.region_id(i);
    [r,c] = find(roi);
    text(ax,mean(c),mean(r),num2str(regions.region_id(i)),'Color','w');
    names(j) = sprintf('%d  %s %g',regions.region_id(i),regions.roi_name{i},regions.slice_index(i));
end
title(ax,'Registered fluorescence and slice IDs');
ax = nexttile(layout);
if ~isempty(rows)
    % Plot in acquisition order and label ticks with actual recorded times.
    imageData = dff(rows,:);
    h = imagesc(ax,imageData,symmetricLimits(imageData));
    colormap(ax,cmap);
    set(h,'AlphaData',isfinite(imageData));
    yticks(ax,1:numel(rows)); yticklabels(ax,names);
    ticks = unique(round(linspace(1,height(q.frames),min(6,height(q.frames)))));
    t = q.frames.trigger_relative_s;
    if all(isnan(t))
        t = q.frames.time_s;
        xlabel(ax,'Acquisition time (s)');
    else
        xlabel(ax,'Time from selected trigger (s)');
        if t(1)<=0 && t(end)>=0 && numel(t)>1
            xline(ax,interp1(t,1:numel(t),0),'w--');
        end
    end
    xticks(ax,ticks); xticklabels(ax,compose('%.2f',t(ticks)));
    cb = colorbar(ax); cb.Label.String = 'Region dF/F';
end
title(ax,'Slice activity');
title(layout,[trialName ' | ' planeTitle],'Interpreter','none');
exportgraphics(fig,fullfile(folder,'slice_qc.pdf'),'ContentType','image','Append',plane>1);
end

function [relativeTime, absoluteTime] = readPrairieViewTimes(xmlFile)
% Return timestamps in seconds: planes x cycles, or 1 x frames for one cycle.
% Assumes ordered cycles and frames, with equal plane counts across cycles.

xmlDocument = xmlread(char(xmlFile));
sequences = xmlDocument.getElementsByTagName('Sequence');
numberOfCycles = sequences.getLength();
firstSequence = sequences.item(0);
numberOfPlanes = firstSequence.getElementsByTagName('Frame').getLength();

relativeTime = zeros(numberOfPlanes, numberOfCycles);
absoluteTime = zeros(numberOfPlanes, numberOfCycles);

for cycleIndex = 1:numberOfCycles
    sequence = sequences.item(cycleIndex - 1);
    frames = sequence.getElementsByTagName('Frame');

    for frameIndex = 1:numberOfPlanes
        frame = frames.item(frameIndex - 1);
        relativeTime(frameIndex, cycleIndex) = ...
            str2double(char(frame.getAttribute('relativeTime')));
        absoluteTime(frameIndex, cycleIndex) = ...
            str2double(char(frame.getAttribute('absoluteTime')));
    end
end

if numberOfCycles == 1
    relativeTime = relativeTime.';
    absoluteTime = absoluteTime.';
end
end%FCN:readPrairieViewTimes

%% ------------------------------------------------------------------------

function [STACK, SET] = getStack(SET, curr, iTrial)
% Load the selected channel using XML filenames/pages, not directory order.
trialName = SET.trial_names_clean{iTrial};
trialFolder = curr.path.(trialName);
xmlFile = fullfile(trialFolder, [SET.trial_names{iTrial}, '.xml']);
xmlDocument = xmlread(xmlFile);
sequences = xmlDocument.getElementsByTagName('Sequence');
numberOfCycles = double(sequences.getLength());
channelPattern = ['(^|_)', regexptranslate('escape', char(SET.Channel)), '(?=_|\.|$)'];
STACK = [];

for cycleIndex = 1:numberOfCycles
    sequence = sequences.item(cycleIndex-1);
    frames = sequence.getElementsByTagName('Frame');
    for frameIndex = 1:double(frames.getLength())
        frame = frames.item(frameIndex-1);
        files = frame.getElementsByTagName('File');
        selectedFile = [];
        for fileIndex = 1:double(files.getLength())
            file = files.item(fileIndex-1);
            filename = char(file.getAttribute('filename'));
            if ~isempty(regexpi(filename, channelPattern, 'once'))
                assert(isempty(selectedFile), ...
                    'Multiple XML File entries match channel %s in one frame.', SET.Channel);
                selectedFile = file;
            end
        end
        assert(~isempty(selectedFile), ...
            'Channel %s is missing from XML filenames at cycle %d, frame %d.', ...
            SET.Channel, cycleIndex, frameIndex);
        filename = char(selectedFile.getAttribute('filename'));
        page = str2double(char(selectedFile.getAttribute('page')));
        assert(isfinite(page) && page >= 1 && page == fix(page), ...
            'Invalid TIFF page for %s.', filename);
        image = imread(fullfile(trialFolder,filename),page);
        snapshot = double(image);
        if isempty(STACK)
            % Preserve source identity and the stored clipping level for frame QC.
            SET.(trialName).sourceXML = xmlFile;
            SET.(trialName).sourceTIFF = {};
            ceiling = SET.SaturationLevel;
            if isempty(ceiling) && isinteger(image), ceiling = double(intmax(class(image))); end
            if isempty(ceiling), ceiling = Inf; end
            SET.(trialName).saturationLevel = ceiling;
            SET.(trialName).xy = [size(snapshot,1), size(snapshot,2)];
            SET.(trialName).channel = SET.Channel;
            STACK = nan([SET.(trialName).xy, SET.(trialName).n_planes, ...
                SET.(trialName).n_frames], 'double');
        end
        if isempty(SET.(trialName).sourceTIFF) || ~strcmp(filename,SET.(trialName).sourceTIFF{end})
            SET.(trialName).sourceTIFF{end+1} = filename;
        end
        if numberOfCycles == 1
            STACK(:,:,1,frameIndex) = snapshot;
        else
            STACK(:,:,frameIndex,cycleIndex) = snapshot;
        end
    end
end
SET.(trialName).sourceTIFF = unique(SET.(trialName).sourceTIFF,'stable');
end%FCN:getStack

%% ------------------------------------------------------------------------

function [STACK,SET] = compressPlanes(STACK, SET)
% Compress selected planes using a maximum intensity projection.
% SET.STACK_mask contains one logical spatial mask per trial.

planes = reshape(SET.max_compression_planes,1,[]);
for iTrial = 1:SET.N
    trialName = SET.trial_names_clean{iTrial};

    % Project the selected planes and intersect their common masks
    projectedStack = max(STACK.(trialName)(:,:,planes,:), [], 3);
    projectedMask = all(SET.STACK_mask.(trialName)(:,:,planes), 3);

    % Exclude pixels outside the projected mask in every frame
    for iFrame = 1:size(projectedStack,4)
        frame = projectedStack(:,:,1,iFrame);
        frame(~projectedMask) = NaN;
        projectedStack(:,:,1,iFrame) = frame;
    end%iFrame

    STACK.(trialName) = projectedStack;
    SET.STACK_mask.(trialName) = projectedMask;

    % Keep original plane times and use the mean across all planes as the reference
    SET.(trialName).relativeTime_planes = SET.(trialName).relativeTime;
    SET.(trialName).absoluteTime_planes = SET.(trialName).absoluteTime;
    SET.(trialName).n_planes_before_compression = SET.(trialName).n_planes;
    SET.(trialName).relativeTime = mean(SET.(trialName).relativeTime(planes,:), 1);
    SET.(trialName).absoluteTime = mean(SET.(trialName).absoluteTime(planes,:), 1);
    SET.(trialName).n_planes = 1;
    SET.(trialName).DataDimensionality = 2;
end%iTrial

SET.DataDimensionality = 2;
end % FCN:compressPlanes

%% ------------------------------------------------------------------------

function [STACK,QC] = affinecorrectMotion(STACK, SET, QC)
% Iterative median-reference affine registration independently per Z-plane.
% Trials use [rows, columns, planes, time], with at least two frames.
% Outputs are double precision and retain dimensions, plane and frame order.
%
% SET.trial_names_clean lists trial fields.
% SET.CorrectMotion_pool:
%   together - concatenate trials and update a shared median each iteration.
%   separate - update an independent median for each trial.
%   template - register trial 1 with an updated median, then register later
%              trials against its fixed corrected median.
% SET.Affine_iter    - outer iterations (default 10).
% SET.Affine_maxIter - optimizer MaximumIterations (default 250).
% Optional SET.STACK_mask supplies spatial logical rectangular common masks,
% as in correctMotion. Shared modes intersect these masks across trials.
% Without STACK_mask, registration uses the full image.
%
% Matches the supplied algorithm: multimodal metric, affine fits, parfor
% over frames, and cubic resampling of the CURRENT corrected frames.
% Uncovered pixels are zero-filled and participate in subsequent medians.
% No intensity normalization or clipping is applied.
% QC stores the common measured support after all affine warps.
% Pixels outside a selected crop retain their input values.
% Requires Image Processing Toolbox. parfor can use Parallel Computing Toolbox.

if ~isfield(SET,'Affine_iter'), SET.Affine_iter = 10; end
if ~isfield(SET,'Affine_maxIter'), SET.Affine_maxIter = 250; end
validateattributes(SET.Affine_iter, {'numeric'}, ...
    {'scalar','real','finite','integer','positive'});
validateattributes(SET.Affine_maxIter, {'numeric'}, ...
    {'scalar','real','finite','integer','positive'});

names = SET.trial_names_clean;
assert(~isempty(names), 'No trials supplied.');
mode = validatestring(SET.CorrectMotion_pool, {'separate','together','template'});
input = STACK;
inputMask = struct();
if isfield(SET,'STACK_mask')
    inputMask = SET.STACK_mask;
end
spatial = zeros(numel(names),3);

% Check trial dimensions and allocate outputs.
for k = 1:numel(names)
    name = names{k};
    movie = input.(name);
    assert(isnumeric(movie) && isreal(movie) && ndims(movie) == 4 && ...
        size(movie,4) >= 2, 'Expected [rows, columns, planes, time] with at least two frames for %s.',name);
    spatial(k,:) = [size(movie,1),size(movie,2),size(movie,3)];
    if ~isfield(SET,'STACK_mask')
        inputMask.(name) = true(spatial(k,:));
    end
    assert(isfield(inputMask,name), 'Missing STACK_mask for %s.',name);
    mask = inputMask.(name);
    assert(islogical(mask) && ndims(mask) <= 3 && ...
        isequal([size(mask,1),size(mask,2),size(mask,3)],spatial(k,:)), ...
        'Expected a spatial logical common mask for %s.',name);
    STACK.(name) = double(movie);
end

% Group trials sharing a registration crop.
if strcmp(mode,'separate')
    groups = num2cell(1:numel(names));
else
    assert(all(all(spatial == spatial(1,:))), ...
        'Shared registration requires matching spatial dimensions.');
    groups = {1:numel(names)};
end

for g = 1:numel(groups)
    group = groups{g};
    first = group(1);
    common = inputMask.(names{first});
    for k = group(2:end)
        common = common & inputMask.(names{k});
    end

    for plane = 1:spatial(first,3)
        % Use the rectangular mask intersection, matching correctMotion.
        footprint = common(:,:,plane);
        rows = find(any(footprint,2));
        cols = find(any(footprint,1));
        assert(~isempty(rows) && ~isempty(cols) && ...
            all(diff(rows)==1) && all(diff(cols)==1) && ...
            all(all(footprint(rows,cols))), ...
            'Expected a nonempty rectangular mask intersection for %s, plane %d.', ...
            names{first},plane);

        if strcmp(mode,'together')
            batches = {group};
        else
            batches = num2cell(group);
        end
        reference = [];
        for b = 1:numel(batches)
            members = batches{b};
            crops = cell(size(members));
            for j = 1:numel(members)
                crop = input.(names{members(j)})(rows,cols,plane,:);
                assert(all(isfinite(crop(:))), ...
                    'Nonfinite input inside the crop for %s.',names{members(j)});
                crops{j} = double(crop);
            end
            counts = cellfun(@(x) size(x,4),crops);
            [aligned,support,displacement,fixed,cornersAfter] = registerAffineCrop(cat(4,crops{:}),SET,reference);

            % Restore original trial boundaries and spatial coordinates.
            offset = 0;
            for j = 1:numel(members)
                name = names{members(j)};
                frames = offset + (1:counts(j));
                STACK.(name)(rows,cols,plane,:) = aligned(:,:,:,frames);
                if ~isfield(QC.(name),'validMask')
                    QC.(name).validMask = false(spatial(members(j),:));
                end
                QC.(name).validMask(rows,cols,plane) = all(support(:,:,frames),3);
                QC.(name).registration(plane).affineReference = fixed;
                QC.(name).registration(plane).affineDisplacement = displacement(frames);
                QC.(name).registration(plane).affineCornersXY = cornersAfter(:,:,frames);
                offset = frames(end);
            end
            if strcmp(mode,'template') && b == 1 && numel(batches) > 1
                reference = median(aligned,4);
            end
        end
    end
end
end % FCN:affinecorrectMotion

function [aligned,support,displacement,fixed,positions] = registerAffineCrop(movie,SET,reference)
% Preserve the user's iterative cubic-warp algorithm on one plane.
nr = size(movie,1);
nc = size(movie,2);
nt = size(movie,4);
assert(nr >= 4 && nc >= 4, ...
    'Affine registration crop must span at least four rows and columns.');
aligned = reshape(movie,nr,nc,nt);
if ~isempty(reference)
    reference = reshape(reference,nr,nc);
end

[optimizer,metric] = imregconfig("multimodal");
optimizer.MaximumIterations = SET.Affine_maxIter;
outputView = imref2d([nr nc]);
[outX,outY] = meshgrid(1:nc,1:nr);
support = true(nr,nc,nt);
% Track corner positions through successive transforms to measure total motion.
corners = [1 1; nc 1; 1 nr; nc nr];
positions = repmat(corners,1,1,nt);

for iteration = 1:SET.Affine_iter
    if isempty(reference)
        fixed = median(aligned,3);
    else
        fixed = reference;
    end

    % Every fit uses the same iteration snapshot and fixed reference.
    current = aligned;
    next = zeros(size(current),'double');
    tformType = SET.Affine_tformType;
    parfor frameIndex = 1:nt
        tform = imregtform(current(:,:,frameIndex),fixed, ...
            tformType,optimizer,metric);
        % Cubic interpolation needs neighboring samples. Check the source footprint
        % of each output location so repeated identity warps retain the full image.
        [srcX,srcY] = transformPointsInverse(tform,outX,outY);
        support(:,:,frameIndex) = cubicSupport(support(:,:,frameIndex),srcX,srcY);
        positions(:,:,frameIndex) = transformPointsForward(tform,positions(:,:,frameIndex));
        next(:,:,frameIndex) = imwarp(current(:,:,frameIndex), ...
            tform,"cubic","OutputView",outputView,"FillValues",0);
    end
    aligned = next;
end
displacement = reshape(max(vecnorm(positions-corners,2,2),[],1),[],1);
aligned = reshape(aligned,nr,nc,1,nt);
end % FCN:registerAffineCrop

%% ------------------------------------------------------------------------

function valid = cubicSupport(previous,x,y)
% A cubic sample uses four neighbors along each fractional axis. Integer
% coordinates use the single measured sample and preserve identity warps.
[nr,nc] = size(previous);
x0 = floor(x); y0 = floor(y);
wholeX = x==x0; wholeY = y==y0;
valid = isfinite(x) & isfinite(y);
for dy = -1:2
    for dx = -1:2
        needed = (~wholeX | dx==0) & (~wholeY | dy==0);
        xx = x0+dx; yy = y0+dy;
        inside = xx>=1 & xx<=nc & yy>=1 & yy<=nr;
        valid(needed & ~inside) = false;
        use = needed & inside;
        valid(use) = valid(use) & previous(sub2ind([nr nc],yy(use),xx(use)));
    end
end
end

function [STACK,QC] = correctMotion(STACK, SET, QC)
% Trials must be X-by-Y-by-Z-by-time arrays (at least two timepoints).
% SET.CorrectMotion_pool: 'together', 'template', or 'separate'.
% SET.NoRMCorre_dim: '2D' or '3D'. Outputs are double precision.
% SET.STACK_mask: common rigid mask per trial used to select the registration crop.

names = SET.trial_names_clean;
assert(~isempty(names), 'No trials supplied.');
mode = validatestring(SET.CorrectMotion_pool, {'separate','together','template'});
use2D = strcmp(validatestring(SET.NoRMCorre_dim, {'2D','3D'}), '2D');
input = STACK;
inputMask = SET.STACK_mask;
spatial = zeros(numel(names),3);

% Check trial dimensions and allocate the output stacks
for k = 1:numel(names)
    name = names{k};
    movie = input.(name);
    mask = inputMask.(name);
    spatial(k,:) = [size(movie,1), size(movie,2), size(movie,3)];
    assert(isnumeric(movie) && isreal(movie) && ndims(movie) == 4 && ...
        size(movie,4) >= 2, 'Expected at least two frames for %s.',name);
    assert(islogical(mask) && ndims(mask) <= 3 && ...
        isequal([size(mask,1),size(mask,2),size(mask,3)],spatial(k,:)), ...
        'Expected a spatial logical common mask for %s.',name);
    STACK.(name) = double(movie);
end

% Group trials that share a registration crop
if strcmp(mode,'separate')
    groups = num2cell(1:numel(names));
else
    assert(all(all(spatial == spatial(1,:))), ...
        'Shared registration requires matching spatial dimensions.');
    groups = {1:numel(names)};
end

for g = 1:numel(groups)
    group = groups{g};
    first = group(1);
    % Intersect the rigid masks across trials in this group
    common = inputMask.(names{first});
    for k = group(2:end)
        common = common & inputMask.(names{k});
    end
    % Register each Z-plane independently in XY, or register the full 3D volume
    if use2D
        planeGroups = num2cell(1:spatial(first,3));
    else
        planeGroups = {1:spatial(first,3)};
    end

    for p = 1:numel(planeGroups)
        planes = planeGroups{p};
        % Find the common rectangular crop for these planes
        footprint = all(common(:,:,planes),3);
        rows = find(any(footprint,2));
        cols = find(any(footprint,1));
        assert(~isempty(rows) && all(diff(rows)==1) && all(diff(cols)==1) ...
            && all(all(footprint(rows,cols))), ...
            'Expected a nonempty rectangular rigid-mask intersection for %s, plane %d.', ...
            names{first},planes(1));

        % Pool frames only in together mode
        if strcmp(mode,'together')
            batches = {group};
        else
            batches = num2cell(group);
        end
        reference = [];
        for b = 1:numel(batches)
            members = batches{b};
            crops = cell(size(members));
            for j = 1:numel(members)
                crop = input.(names{members(j)})(rows,cols,planes,:);
                assert(all(isfinite(crop(:))), 'Nonfinite input inside the crop for %s.',names{members(j)});
                crops{j} = double(crop);
            end
            counts = cellfun(@(x) size(x,4),crops);
            [aligned,shifts,fixed] = registerCrop(cat(4,crops{:}),SET,reference);
            offset = 0;
            for j = 1:numel(members)
                name = names{members(j)};
                frames = offset + (1:counts(j));
                offset = frames(end);
                % Write the corrected crop back at its original coordinates
                STACK.(name)(rows,cols,planes,:) = aligned(:,:,:,frames);
                % Bound the support loss with the largest applied patch shift
                % on each axis, rounding fractional displacements outwards.
                dim = 2 + (numel(planes)>1);
                axisShift = zeros(numel(frames),dim);
                motion = zeros(numel(frames),1);
                for f = 1:numel(frames)
                    patch = shifts(frames(f)).shifts;
                    if isfield(shifts,'shifts_up') && ~isempty(shifts(frames(f)).shifts_up)
                        patch = shifts(frames(f)).shifts_up;
                    end
                    patch = reshape(double(patch),[],dim);
                    assert(~isempty(patch) && all(isfinite(patch(:))), ...
                        'Nonfinite registration displacement in %s, frame %d.',name,f);
                    axisShift(f,:) = max(abs(patch),[],1);
                    motion(f) = max(vecnorm(patch,2,2));
                end
                margin = ceil(max(axisShift,[],1));
                if ~isfield(QC.(name),'validMask'), QC.(name).validMask = inputMask.(name); end
                valid = QC.(name).validMask(rows,cols,planes);
                padded = padarray(valid,margin,false);
                cropped = imerode(padded,ones(2*margin+1));
                cropShape = [numel(rows) numel(cols) numel(planes)];
                idx = arrayfun(@(m,n) m+(1:n),margin,cropShape(1:dim),'UniformOutput',false);
                valid = cropped(idx{:});
                QC.(name).validMask(rows,cols,planes) = valid;
                % Keep signed native patch vectors once per plane group as
                % returned by NoRMCorre, alongside the compact frame metrics.
                QC.(name).registration(planes(1)).nonrigidPatchShifts = {shifts(frames).shifts};
                QC.(name).registration(planes(1)).registeredPlanes = planes;
                for z = 1:numel(planes)
                    QC.(name).registration(planes(z)).nonrigidReference = fixed(:,:,z);
                    QC.(name).registration(planes(z)).nonrigidDisplacement = motion;
                end
            end

            if strcmp(mode,'template') && b == 1 && numel(batches) > 1
                % Use the corrected first trial as the template for subsequent trials
                reference = mean(aligned,4,'omitnan');
            end
        end
    end
end
end % FCN:correctMotion

function [aligned,shifts,fixed] = registerCrop(movie,SET,reference)
[nr,nc,nz,nt] = size(movie);
dim = 3;
if nz == 1
    dim = 2;
    movie = reshape(movie,nr,nc,nt);
end
assert(nr >= 2 && nc >= 2,'Registration crop must span at least two rows and columns.');
% Non-rigid NoRMCorre parameters
options = NoRMCorreSetParms(...
    'd1',nr,'d2',nc,'d3',nz, ...
    'iter',SET.NoRMCorre_iter,...
    'print_msg',false,...
    'use_parallel',true, ...
    'upd_template',isempty(reference),...
    'boundary','copy', ...
    'grid_size',axesParam(SET.NoRMCorre_gridSize,dim), ...
    'overlap_pre',axesParam(SET.NoRMCorre_overlap_pre,dim), ...
    'overlap_post',axesParam(SET.NoRMCorre_overlap_post,dim), ...
    'mot_uf',axesParam(SET.NoRMCorre_mot_uf,dim), ...
    'max_shift',axesParam(SET.NoRMCorre_max_shift,dim), ...
    'min_patch_size', SET.NoRMCorre_min_patch_size, ...
    'max_dev',axesParam(SET.NoRMCorre_max_dev,dim));
% Piecewise-rigid / non-rigid correction
[aligned,shifts,fixed] = normcorre_batch(movie,options,reference);
aligned = reshape(double(aligned),nr,nc,nz,nt);
end % FCN:registerCrop

function value = axesParam(value,dim)
% Preserve NoRMCorre's scalar and length-two parameter expansion in 3D.
if dim == 2 && numel(value)>2
    value = value(1:2);
end
end % FCN:axesParam

%% ------------------------------------------------------------------------

function STACK = filterImages(STACK, SET)
% Filter each XY image independently in X-by-Y-by-Z-by-time trial arrays.
% sp: Gaussian sigma, median window width, or [median width, Gaussian sigma].
smoothingParameters = SET.SmoothData_spat;
filterType = SET.SmoothData_spat_type;

for trialIndex = 1:numel(SET.trial_names_clean)
    trialName = SET.trial_names_clean{trialIndex};
    if isempty(filterType), continue; end
    trial = double(STACK.(trialName));
    trialSize = size(trial);

    % Combine plane and time indices for parallel image filtering.
    images = reshape(trial, size(trial, 1), size(trial, 2), []);
    filteredImages = zeros(size(images), 'like', images);

    parfor imageIndex = 1:size(images, 3)
        image = images(:, :, imageIndex);
        switch filterType
            case 'gauss'
                image = imgaussfilt(image, smoothingParameters);
            case 'med'
                image = medfilt2(image, [smoothingParameters smoothingParameters]);
            case 'med-gauss'
                image = medfilt2(image, ...
                    [smoothingParameters(1) smoothingParameters(1)]);
                image = imgaussfilt(image, smoothingParameters(2));
            case 'gauss-med'
                image = imgaussfilt(image, smoothingParameters(2));
                image = medfilt2(image, ...
                    [smoothingParameters(1) smoothingParameters(1)]);
        end
        filteredImages(:, :, imageIndex) = image;
    end

    STACK.(trialName) = reshape(filteredImages, trialSize);
end
% Now, filter temporal dimension
if ~isempty(SET.SmoothData_temp_type)
    for iTrial = 1:SET.N
        switch SET.SmoothData_temp_type
            case 'movmean'
                STACK.(SET.trial_names_clean{iTrial}) = movmean(STACK.(SET.trial_names_clean{iTrial}), SET.SmoothData_temp, 4);
            case 'movmedian'
                STACK.(SET.trial_names_clean{iTrial}) = movmedian(STACK.(SET.trial_names_clean{iTrial}), SET.SmoothData_temp, 4);
            case 'butter'
                % Design filter
                Fs = median(1./diff(SET.(SET.trial_names_clean{iTrial}).relativeTime(1,:)));
                Fc = SET.SmoothData_temp(2);
                Wn = Fc/(Fs/2);
                % Safety check: butter requires 0 < Wn < 1
                if Wn >= 1
                    warning(['Requested cutoff %.3f exceeds Nyquist frequency %.3f. ' ...
                        'Using %.3f instead.'], ...
                        Fc, Fs/2, 0.99*(Fs/2));

                    Wn = 0.99;
                elseif Wn <= 0
                    warning('Invalid cutoff frequency %.3f. Using minimum positive cutoff.', Fc);
                    Wn = eps;
                end
                [b,a] = butter(SET.SmoothData_temp(1), Wn, 'low');
                % Reshape data and filter
                X = STACK.(SET.trial_names_clean{iTrial});
                X = permute(X,[4 1 2 3]);
                X = filtfilt(b,a,X);
                X = ipermute(X,[4 1 2 3]);
                % Put back
                STACK.(SET.trial_names_clean{iTrial}) = X;
                clear X
        end%switch
    end%iTrial


end%if fitler temporal
end%FCN:filterImages

%% ------------------------------------------------------------------------

function STACK = detrendMovies(STACK, SET)
setting = SET.Detrend;
if isnumeric(setting)
    validateattributes(setting, {'numeric'}, {'scalar','real','finite','integer','nonnegative'});
    if setting == 0
        return
    end
    mode = 'poly';
    degree = setting;
elseif ischar(setting) || (isstring(setting) && isscalar(setting))
    setting = char(setting);
    if strcmp(setting, 'exp2')
        mode = 'exp2';
    elseif startsWith(setting, 'log-')
        mode = 'log';
        degree = str2double(setting(5:end));
        validateattributes(degree, {'double'}, {'scalar','real','finite','integer','nonnegative'});
    elseif startsWith(setting, 'hpf-')
        mode = 'hpf';
        cutoff = str2double(setting(5:end));
        validateattributes(cutoff, {'double'}, {'scalar','real','finite','positive'});
    else
        error('Unknown SET.Detrend mode: %s', setting);
    end
else
    error('SET.Detrend must be a polynomial degree or a detrending mode.');
end

for iTrial = 1:SET.N
    trialName = SET.trial_names_clean{iTrial};
    nFrames = size(STACK.(trialName), 4);
    frames = (1:nFrames)';
    for plane = 1:size(STACK.(trialName), 3)
        % Work in time-by-pixel order within the valid spatial mask.
        movie = STACK.(trialName)(:,:,plane,:);
        pixels = reshape(movie, [], nFrames);
        mask = SET.STACK_mask.(trialName)(:,:,plane);
        if ~any(mask(:)), continue; end
        traces = pixels(mask(:), :)';
        baseline = median(traces, 1, 'omitnan');

        switch mode
            case 'exp2'
                planeTrace = median(traces, 2, 'omitnan');
                valid = isfinite(planeTrace);
                assert(nnz(valid) >= 4, 'exp2 requires four valid frames in %s, plane %d.', trialName, plane);
                model = fit(frames(valid), planeTrace(valid), 'exp2');
                traces = detrend(traces - model(frames), 1, 'omitnan');
            case 'hpf'
                intervals = diff(SET.(trialName).relativeTime(plane,:));
                assert(all(isfinite(intervals) & intervals > 0) && nFrames > 6, ...
                    'High-pass filtering requires at least seven increasing frame times in %s, plane %d.', trialName, plane);
                nyquist = 0.5 / median(intervals);
                assert(cutoff < nyquist, 'High-pass cutoff must be below %.4g Hz in %s, plane %d.', nyquist, trialName, plane);
                [b,a] = butter(2, cutoff / nyquist, 'high');
                traces = filtfilt(b, a, traces);
            otherwise
                assert(degree < nFrames, 'Polynomial degree must be below the frame count in %s.', trialName);
                if strcmp(mode, 'log')
                    if any(traces(:) <= 0)
                        warning('CRAPview:logNonPositive', 'Clamping non-positive fluorescence to eps before log detrending.');
                        traces(traces <= 0) = eps;
                    end
                    traces = exp(detrend(log(traces), degree, 'omitnan'));
                else
                    traces = detrend(traces, degree, 'omitnan');
                end
        end

        pixels(mask(:), :) = (traces + baseline)';
        STACK.(trialName)(:,:,plane,:) = reshape(pixels, size(movie));
    end
end
end % FCN:detrendMovies

%% ------------------------------------------------------------------------

function [STACK_seg, Segmentation] = segmentImages(STACK, SET, measurement, QC)
% Segment XY planes in X-by-Y-by-Z-by-time trial arrays.
% together: segment concatenated trials once per plane, then share labels.
% template: segment trial 1 once per plane, then share labels.
% separate: segment each trial and plane independently.
% Summary statistics always describe the individual trial, before averaging.
% STACK is the detection movie. Extract region means from measurement and
% retain the original acquisition slots, including excluded frames.
% STACK_seg averages region pixels for BOTH methods, including background (ID 0).
% Background is averaged separately within each plane and trial.
% With segmentation disabled, STACK_seg equals measurement. Integer segmented data
% are converted to double to preserve fractional region means.
% Results: Segmentation.(trialName)(planeIndex).pockets_labeled / summary_stats.

trialNames = SET.trial_names_clean;
numberOfTrials = numel(trialNames);
method = char(SET.segmentation_method);
mode = validatestring(SET.CorrectMotion_pool, {'together', 'template', 'separate'});
segmentationEnabled = ~isempty(method);
if segmentationEnabled
    method = validatestring(method, {'CalciSeg', 'manualSliceSeg'});
end

segmentationArguments = {};
quiet = false;
if segmentationEnabled
    settings = SET.segmentation_settings;
    if isfield(settings, 'quiet')
        quiet = settings.quiet;
        settings = rmfield(settings, 'quiet'); % Wrapper option, not a segmenter argument.
    end
    if strcmp(method,'manualSliceSeg'), settings.Colormap = SET.colmap; end
    settingNames = fieldnames(settings);
    for settingIndex = 1:numel(settingNames)
        segmentationArguments(end+1:end+2) = ...
            {settingNames{settingIndex}, settings.(settingNames{settingIndex})};
    end
end

% Shared segmentation requires corresponding planes and image sizes.
spatialSizes = zeros(numberOfTrials, 3);
for trialIndex = 1:numberOfTrials
    trial = STACK.(trialNames{trialIndex});
    spatialSizes(trialIndex, :) = [size(trial, 1), size(trial, 2), size(trial, 3)];
end
if segmentationEnabled && ~strcmp(mode, 'separate')
    assert(all(all(spatialSizes == spatialSizes(1, :))), ...
        'Shared segmentation requires matching XY sizes and plane counts.');
    trialGroups = {1:numberOfTrials};
else
    trialGroups = num2cell(1:numberOfTrials);
end

STACK_seg = measurement;
if segmentationEnabled
    for trialIndex = 1:numberOfTrials
        trialName = trialNames{trialIndex};
        if ~isfloat(STACK_seg.(trialName))
            STACK_seg.(trialName) = double(STACK_seg.(trialName));
        end
    end
end

Segmentation = struct();
for groupIndex = 1:numel(trialGroups)
    trialIndices = trialGroups{groupIndex};
    firstTrial = STACK.(trialNames{trialIndices(1)});
    for planeIndex = 1:size(firstTrial, 3)
        if segmentationEnabled
            sourceIndices = trialIndices(1);
            if strcmp(mode, 'together'), sourceIndices = trialIndices; end
            % Shared labels use geometry measured in every contributing
            % trial; a moving valid border must not drive ROI detection.
            commonMask = true(size(firstTrial,1),size(firstTrial,2));
            for member = trialIndices
                commonMask = commonMask & SET.STACK_mask.(trialNames{member})(:,:,planeIndex);
            end
            sourceMovies = cell(1, numel(sourceIndices));
            for sourceIndex = 1:numel(sourceIndices)
                name = trialNames{sourceIndices(sourceIndex)};
                good = ~QC.(name).planes(planeIndex).frames.excluded;
                movie = getPlane(STACK.(name),planeIndex);
                movie = reshape(movie,[],size(movie,3));
                valid = commonMask;
                movie(~valid(:),:) = 0;
                sourceMovies{sourceIndex} = reshape(movie(:,good),size(valid,1),size(valid,2),nnz(good));
            end
            sourceMovie = cat(3, sourceMovies{:});
            if strcmp(method, 'CalciSeg') && ~isfloat(sourceMovie)
                sourceMovie = double(sourceMovie);
            end
            if size(sourceMovie,3)==0 || ~any(commonMask(:))
                % An unusable template cannot provide meaningful shared labels.
                assert(~strcmp(mode,'template') || numel(trialIndices)==1, ...
                    'No usable template frames in plane %d.',planeIndex);
                labelImage = zeros(size(firstTrial,1),size(firstTrial,2));
                sourceSummary = struct();
            elseif quiet
                evalc('[labelImage, sourceSummary] = feval(method, sourceMovie, segmentationArguments{:});');
            else
                [labelImage, sourceSummary] = ...
                    feval(method, sourceMovie, segmentationArguments{:});
            end
            labelImage(~commonMask) = 0;
            clear sourceMovies sourceMovie
        else
            labelImage = reshape(1:size(firstTrial, 1)*size(firstTrial, 2), ...
                size(firstTrial, 1), size(firstTrial, 2));
            sourceSummary = struct([]);
        end

        for trialIndex = trialIndices
            trialName = trialNames{trialIndex};
            planeMovie = getPlane(measurement.(trialName), planeIndex);
            % Keep shared IDs stable and remove invalid geometry for this trial.
            trialLabels = labelImage;
            trialLabels(~SET.STACK_mask.(trialName)(:,:,planeIndex)) = 0;
            summary = sourceSummary;
            if segmentationEnabled
                summary = trialSummary(planeMovie,trialLabels,sourceSummary);
            end
            Segmentation.(trialName)(planeIndex).pockets_labeled = trialLabels;
            Segmentation.(trialName)(planeIndex).summary_stats = summary;

            if segmentationEnabled
                pixelTraces = reshape(planeMovie, [], size(planeMovie, 3));
                if ~isfloat(pixelTraces), pixelTraces = double(pixelTraces); end
                regionIDs = unique(trialLabels(:)); % Include background (ID 0).
                valid = SET.STACK_mask.(trialName)(:,:,planeIndex);
                for regionIndex = 1:numel(regionIDs)
                    regionPixels = trialLabels(:) == regionIDs(regionIndex) & valid(:);
                    meanTrace = mean(pixelTraces(regionPixels, :), 1, 'omitnan');
                    pixelTraces(regionPixels, :) = repmat(meanTrace, nnz(regionPixels), 1);
                end
                segmentedPlane = reshape(pixelTraces, ...
                    size(planeMovie, 1), size(planeMovie, 2), 1, size(planeMovie, 3));
                STACK_seg.(trialName)(:, :, planeIndex, :) = segmentedPlane;
            end
        end
    end
end
end

function planeMovie = getPlane(trial, planeIndex)
planeMovie = reshape(trial(:, :, planeIndex, :), size(trial, 1), size(trial, 2), size(trial, 4));
end

function summary = trialSummary(planeMovie, labelImage, sourceSummary)
% Retain segmentation metadata; recompute the agreed activity fields per trial.
% regionIDs identifies the label represented by each row of avgTCs/granule_Corr.
summary = sourceSummary;
regionIDs = unique(labelImage(labelImage > 0));
numberOfRegions = numel(regionIDs);
pixelTraces = reshape(double(planeMovie), [], size(planeMovie, 3));
pixelTraces(~isfinite(pixelTraces)) = NaN;
% A clipped slice can disappear in one trial. Preserve the anatomical
% name and slice index for each surviving ID before compacting trace rows.
if isfield(sourceSummary,'roiIndex')
    summary.roiIndex = sourceSummary.roiIndex(regionIDs);
    summary.sliceIndex = sourceSummary.sliceIndex(regionIDs);
end
summary.regionIDs = regionIDs(:);
summary.avgTCs = nan(numberOfRegions, size(planeMovie, 3));
summary.granule_Corr = nan(numberOfRegions, 1);
summary.pixelCounts = zeros(numberOfRegions, 1);
statisticNames = {'Avg', 'Std', 'Max', 'Min', 'Median'};
for statisticIndex = 1:numel(statisticNames)
    summary.(['granule_' statisticNames{statisticIndex} '_img']) = nan(size(labelImage));
end
for regionIndex = 1:numberOfRegions
    regionPixels = labelImage(:) == regionIDs(regionIndex);
    traces = pixelTraces(regionPixels, :);
    meanTrace = mean(traces, 1, 'omitnan');
    summary.avgTCs(regionIndex, :) = meanTrace;
    summary.granule_Corr(regionIndex) = meanPairCorrelation(traces);
    summary.pixelCounts(regionIndex) = nnz(regionPixels);
    statistics = [mean(meanTrace, 'omitnan'), std(meanTrace, 0, 'omitnan'), ...
        max(meanTrace, [], 'omitnan'), min(meanTrace, [], 'omitnan'), ...
        median(meanTrace, 'omitnan')];
    for statisticIndex = 1:numel(statisticNames)
        fieldName = ['granule_' statisticNames{statisticIndex} '_img'];
        summary.(fieldName)(regionPixels) = statistics(statisticIndex);
    end
end
end

function value = meanPairCorrelation(traces)
% Remove jointly missing frames before selecting the fast correlation path.
traces = traces(:,any(isfinite(traces),1));
% Compute the mean without allocating a pixels-by-pixels correlation matrix.
value = NaN;
if size(traces, 2) < 2
    return
end
if all(isfinite(traces(:)))
    centered = traces - mean(traces, 2);
    magnitudes = sqrt(sum(centered.^2, 2));
    valid = magnitudes > 0;
    normalized = centered(valid, :) ./ magnitudes(valid);
    count = size(normalized, 1);
    if count >= 2
        value = (sum(sum(normalized, 1).^2) - count) / (count*(count-1));
        value = max(-1, min(1, value));
    end
else
    % Pairwise finite samples when missing values differ between pixels.
    correlationSum = 0;
    pairCount = 0;
    for firstPixel = 1:size(traces, 1)-1
        for secondPixel = firstPixel+1:size(traces, 1)
            shared = isfinite(traces(firstPixel, :)) & isfinite(traces(secondPixel, :));
            if nnz(shared) < 2
                continue
            end
            first = traces(firstPixel, shared);
            second = traces(secondPixel, shared);
            first = first - mean(first);
            second = second - mean(second);
            denominator = norm(first)*norm(second);
            if denominator > 0
                correlationSum = correlationSum + max(-1, min(1, sum(first.*second)/denominator));
                pairCount = pairCount + 1;
            end
        end
    end
    if pairCount > 0
        value = correlationSum / pairCount;
    end
end
end

%% ------------------------------------------------------------------------

function [labelImage, summary] = manualSliceSeg(planeMovie, varargin)
% Draw and slice ROIs in a rows-by-columns-by-time movie.
% Options: NumberOfROIs (2), SlicesPerROI (8 or one count per ROI),
% ROINames (optional), SliceOptions (optional; PixelSize = [dy dx]).
% ROIs follow drawing order; slices follow the extracted midline direction.
% avgTCs is regions-by-time; granule_Corr is regions-by-1.
% Summary image fields contain statistics of each region's mean trace.
% Background: label 0, summary NaN. Requires Image Processing Toolbox.

parser = inputParser;
addParameter(parser, 'NumberOfROIs', 2);
addParameter(parser, 'SlicesPerROI', 8);
addParameter(parser, 'ROINames', {});
addParameter(parser, 'SliceOptions', struct());
addParameter(parser, 'Colormap', turbo);
parse(parser, varargin{:});
settings = parser.Results;
numberOfROIs = settings.NumberOfROIs;
slicesPerROI = double(settings.SlicesPerROI(:));
if isscalar(slicesPerROI)
    slicesPerROI = repmat(slicesPerROI, numberOfROIs, 1);
end
roiNames = cellstr(string(settings.ROINames));
if isempty(roiNames)
    roiNames = arrayfun(@(index) sprintf('ROI %d', index), ...
        1:numberOfROIs, 'UniformOutput', false);
end
sliceOptions = settings.SliceOptions;
movie = double(planeMovie);
movie(~isfinite(movie)) = NaN;
imageSize = [size(movie, 1), size(movie, 2)];
displayImage = std(movie, 0, 3, 'omitnan');
displayImage(~isfinite(displayImage)) = 0;
displayLimit = quantile(displayImage(:), 0.999);
displayLimits = symmetricLimits(displayLimit);
figureHandle = figure('Name', 'Manual ROI slicing', 'Color', 'w', ...
    'Units', 'normalized', 'Position', [0.05 0.05 0.9 0.85]);
figureCleanup = onCleanup(@() closeFigure(figureHandle)); %#ok<NASGU>
axesHandle = axes('Parent', figureHandle);

while true
    labelImage = zeros(imageSize);
    occupiedRaw = false(imageSize);
    cla(axesHandle);
    imagesc(axesHandle, displayImage, displayLimits);
    axis(axesHandle, 'image');
    axis(axesHandle, 'off');
    colormap(axesHandle, settings.Colormap);
    hold(axesHandle, 'on');
    labelOffset = 0;

    for roiIndex = 1:numberOfROIs
        while true
            title(axesHandle, sprintf('Draw %s (%d/%d); double-click to finish', ...
                roiNames{roiIndex}, roiIndex, numberOfROIs), 'Interpreter', 'none');
            drawnow;
            polygon = drawpolygon(axesHandle);
            if ~isgraphics(figureHandle)
                error('manualSliceSeg:Cancelled', 'Segmentation figure closed.');
            end
            if isempty(polygon) || ~isvalid(polygon) || size(polygon.Position, 1) < 3
                if ~isempty(polygon) && isvalid(polygon), delete(polygon); end
                choice = questdlg('Polygon unfinished. Draw at least three vertices, then double-click.', ...
                    'Draw ROI again', 'Redraw', 'Cancel', 'Redraw');
                if strcmp(choice, 'Redraw'), continue; end
                error('manualSliceSeg:Cancelled', 'Segmentation cancelled.');
            end
            rawMask = createMask(polygon);
            delete(polygon);
            if any(rawMask(:) & occupiedRaw(:))
                uiwait(warndlg('ROIs overlap. Please redraw this ROI.', 'Overlap', 'modal'));
                continue
            end
            try
                localLabels = sliceMask( ...
                    rawMask, slicesPerROI(roiIndex), sliceOptions);
            catch exception
                choice = questdlg(exception.message, 'Slicing failed', ...
                    'Redraw', 'Cancel', 'Redraw');
                if strcmp(choice, 'Redraw')
                    continue
                end
                rethrow(exception)
            end
            if any(localLabels(:) > 0 & labelImage(:) > 0)
                uiwait(warndlg('Smoothed ROIs overlap. Please redraw this ROI.', ...
                    'Overlap', 'modal'));
                continue
            end
            centroids = zeros(slicesPerROI(roiIndex), 2);
            for sliceIndex = 1:slicesPerROI(roiIndex)
                [rows, columns] = find(localLabels == sliceIndex);
                centroids(sliceIndex, :) = [mean(columns), mean(rows)];
            end
            if any(~isfinite(centroids(:)))
                uiwait(warndlg(['Some slices contain no pixels. Redraw a larger ROI ' ...
                    'or cancel and request fewer slices.'], 'Empty slices', 'modal'));
                continue
            end
            break
        end

        sliceOrder = 1:slicesPerROI(roiIndex); % Already ordered along the midline.
        for sliceIndex = 1:numel(sliceOrder)
            regionMask = localLabels == sliceOrder(sliceIndex);
            regionID = labelOffset + sliceIndex;
            labelImage(regionMask) = regionID;
            boundaries = bwboundaries(regionMask, 'noholes');
            for boundaryIndex = 1:numel(boundaries)
                boundary = boundaries{boundaryIndex};
                plot(axesHandle, boundary(:, 2), boundary(:, 1), 'k-', 'LineWidth', 0.5, ...
                    'HitTest', 'off', 'PickableParts', 'none');
            end
            center = centroids(sliceOrder(sliceIndex), :);
            text(axesHandle, center(1), center(2), num2str(regionID), ...
                'Color', 'w', 'BackgroundColor', 'k', 'HorizontalAlignment', 'center', ...
                'HitTest', 'off', 'PickableParts', 'none');
        end
        occupiedRaw = occupiedRaw | rawMask;
        labelOffset = labelOffset + slicesPerROI(roiIndex);
    end
    title(axesHandle, 'Review numbered slices');
    choice = questdlg('Keep this segmentation?', 'Review segmentation', ...
        'Accept', 'Redraw all', 'Cancel', 'Accept');
    if strcmp(choice, 'Accept')
        break
    elseif ~strcmp(choice, 'Redraw all')
        error('manualSliceSeg:Cancelled', 'Segmentation cancelled.');
    end
end
closeFigure(figureHandle);

numberOfRegions = sum(slicesPerROI);
pixelTraces = reshape(movie, [], size(movie, 3));
summary.avgTCs = nan(numberOfRegions, size(movie, 3));
summary.granule_Corr = nan(numberOfRegions, 1);
statisticNames = {'Avg', 'Std', 'Max', 'Min', 'Median'};
for statisticIndex = 1:numel(statisticNames)
    fieldName = ['granule_' statisticNames{statisticIndex} '_img'];
    summary.(fieldName) = nan(imageSize);
end
summary.roiNames = roiNames;
summary.roiIndex = repelem((1:numberOfROIs)', slicesPerROI);
summary.sliceIndex = zeros(numberOfRegions, 1);
summary.pixelCounts = zeros(numberOfRegions, 1);
for roiIndex = 1:numberOfROIs
    summary.sliceIndex(summary.roiIndex == roiIndex) = (1:slicesPerROI(roiIndex))';
end
for regionID = 1:numberOfRegions
    regionPixels = labelImage(:) == regionID;
    traces = pixelTraces(regionPixels, :);
    meanTrace = mean(traces, 1, 'omitnan');
    summary.avgTCs(regionID, :) = meanTrace;
    summary.granule_Corr(regionID) = meanPairCorrelation(traces);
    summary.pixelCounts(regionID) = nnz(regionPixels);
    statistics = [mean(meanTrace, 'omitnan'), std(meanTrace, 0, 'omitnan'), ...
        max(meanTrace, [], 'omitnan'), min(meanTrace, [], 'omitnan'), ...
        median(meanTrace, 'omitnan')];
    for statisticIndex = 1:numel(statisticNames)
        fieldName = ['granule_' statisticNames{statisticIndex} '_img'];
        summary.(fieldName)(regionPixels) = statistics(statisticIndex);
    end
end
end

function closeFigure(figureHandle)
if isgraphics(figureHandle)
    delete(figureHandle);
end
end

function labels = sliceMask(mask, numberOfSlices, options)
defaults = struct('SmoothMode', "openclose", 'SmoothRadius', 5, ...
    'FillHoles', true, 'MinArea', 0, 'LocalMaxFcn', [], 'MinMidDist', 0, ...
    'SkelPruneSpurs', 15, 'UseBWskelIfAvail', true, 'MinSkelPixels', 30, ...
    'MidlineN', 1200, 'SmoothWin', 21, 'ExtendStep', 0.5, ...
    'MaxExtendSteps', 5000, 'PixelSize', [1 1]);
names = fieldnames(defaults);
for optionIndex = 1:numel(names)
    name = names{optionIndex};
    if ~isfield(options, name) || isempty(options.(name))
        options.(name) = defaults.(name);
    end
end

% Smooth the outline before extracting its midline.
if options.FillHoles, mask = imfill(mask, 'holes'); end
if options.MinArea > 0, mask = bwareaopen(mask, round(options.MinArea)); end
if options.SmoothRadius > 0
    disk = strel('disk', options.SmoothRadius, 0);
    switch string(options.SmoothMode)
        case "open", mask = imopen(mask, disk);
        case "close", mask = imclose(mask, disk);
        case "openclose", mask = imclose(imopen(mask, disk), disk);
        case "closeopen", mask = imopen(imclose(mask, disk), disk);
        case "none"
        otherwise, error('Unknown SmoothMode.');
    end
end
if options.FillHoles, mask = imfill(mask, 'holes'); end
if options.MinArea > 0, mask = bwareaopen(mask, round(options.MinArea)); end
assert(any(mask(:)), 'ROI is empty after smoothing. Reduce SmoothRadius.');

edgeDistance = bwdist(~mask);
if isempty(options.LocalMaxFcn)
    ridge = imregionalmax(edgeDistance);
else
    ridge = options.LocalMaxFcn(edgeDistance.^2);
end
ridge = ridge & mask & edgeDistance >= options.MinMidDist;
skeleton = bwmorph(ridge, 'thin', Inf);
if options.UseBWskelIfAvail
    fullSkeleton = bwskel(mask);
else
    fullSkeleton = bwmorph(mask, 'skel', Inf);
end
if nnz(skeleton) < options.MinSkelPixels, skeleton = fullSkeleton; end
pruned = bwmorph(skeleton, 'spur', options.SkelPruneSpurs);
if nnz(pruned) >= 2, skeleton = pruned; end
skeleton = largestComponent(skeleton & mask);
if nnz(skeleton) < 2, skeleton = largestComponent(fullSkeleton); end
assert(nnz(skeleton) >= 2, 'ROI is too small to extract a midline.');

% Trace the skeleton between two distant endpoints.
[row, column] = find(skeleton, 1);
for sweep = 1:2
    distance = bwdistgeodesic(skeleton, column, row, 'quasi-euclidean');
    distance(~isfinite(distance)) = Inf;
    reachable = distance;
    reachable(~isfinite(reachable)) = -Inf;
    [~, endpoint] = max(reachable(:));
    [row, column] = ind2sub(size(mask), endpoint);
end
midline = [column row];
neighbors = [-1 -1; 0 -1; 1 -1; -1 0; 1 0; -1 1; 0 1; 1 1];
while distance(row, column) > 0
    candidates = [column row] + neighbors;
    inside = candidates(:, 1) >= 1 & candidates(:, 1) <= size(mask, 2) & ...
        candidates(:, 2) >= 1 & candidates(:, 2) <= size(mask, 1);
    candidates = candidates(inside, :);
    indices = sub2ind(size(mask), candidates(:, 2), candidates(:, 1));
    [nextDistance, nextIndex] = min(distance(indices));
    assert(nextDistance < distance(row, column), 'Cannot trace the midline.');
    column = candidates(nextIndex, 1);
    row = candidates(nextIndex, 2);
    midline(end+1, :) = [column row]; %#ok<AGROW>
end
midline = flipud(midline);

% Resample, smooth, and extend both ends to the ROI boundary.
if size(midline, 1) >= 3
    stations = arcLength(midline, options.PixelSize);
    midline = interp1(stations, midline, ...
        linspace(0, stations(end), options.MidlineN)', 'linear');
    if options.SmoothWin > 0
        window = max(3, options.SmoothWin);
        window = window + (mod(window, 2) == 0);
        midline = movmean(midline, window, 1);
    end
end
midline = extendEnd(flipud(midline), mask, options);
midline = extendEnd(flipud(midline), mask, options);
midline = midline([true; any(diff(midline, 1, 1) ~= 0, 2)], :);
stations = arcLength(midline, options.PixelSize);
assert(stations(end) > 0, 'Midline has zero length.');

% Assign pixels to equally spaced midline stations.
pixels = round(midline);
indices = sub2ind(size(mask), pixels(:, 2), pixels(:, 1));
[uniqueIndices, ~, groups] = unique(indices);
stationValues = accumarray(groups, stations, [], @max);
pathMask = false(size(mask));
pathMask(uniqueIndices) = true;
stationImage = zeros(size(mask));
stationImage(uniqueIndices) = stationValues;
[~, nearest] = bwdist(pathMask);
bins = floor(stationImage(nearest) / max(stationValues) * numberOfSlices) + 1;
labels = zeros(size(mask));
labels(mask) = min(numberOfSlices, bins(mask));
end

function component = largestComponent(mask)
components = bwconncomp(mask, 8);
component = false(size(mask));
if components.NumObjects > 0
    [~, largest] = max(cellfun(@numel, components.PixelIdxList));
    component(components.PixelIdxList{largest}) = true;
end
end

function stations = arcLength(midline, pixelSize)
steps = diff(midline, 1, 1) .* pixelSize([2 1]);
stations = [0; cumsum(hypot(steps(:, 1), steps(:, 2)))];
end

function midline = extendEnd(midline, mask, options)
direction = midline(end, :) - midline(max(1, end-9), :);
if norm(direction) == 0, return; end
step = options.ExtendStep * direction / norm(direction);
for extensionIndex = 1:options.MaxExtendSteps
    point = midline(end, :) + step;
    pixel = round(point);
    if pixel(1) < 1 || pixel(1) > size(mask, 2) || ...
            pixel(2) < 1 || pixel(2) > size(mask, 1) || ~mask(pixel(2), pixel(1))
        break
    end
    midline(end+1, :) = point; %#ok<AGROW>
end
end

%% ------------------------------------------------------------------------

function PCA = embedTrialFrames(Segmentation,SET,QC)
% Fit one PCA per animal. Rows are acquired frames (volumes for multiplane
% data), and columns are segmented regions identified within each plane.
PCA = struct('status','disabled');
if ~SET.FramePCA, return; end
names = SET.trial_names_clean;
if isempty(SET.segmentation_method)
    PCA.status = 'No segmentation traces.';
    return
end
% Independent automatic segmentations have no cross-trial correspondence.
% Manual slice labels follow the configured ROI order and slice numbering.
if numel(names)>1 && strcmp(SET.CorrectMotion_pool,'separate') && ~strcmp(SET.segmentation_method,'manualSliceSeg')
    PCA.status = 'Joint PCA requires matched regions across trials.';
    return
end

% Intersect (plane, region ID) pairs so clipped or missing ROIs cannot
% silently shift the feature columns. Preserve original frame and trial IDs.
keys = cell(numel(names),1);
movies = cell(numel(names),1);
frameInfo = cell(numel(names),1);
for k = 1:numel(names)
    name = names{k};
    n = size(SET.(name).relativeTime,2);
    keys{k} = zeros(0,2);
    movies{k} = zeros(n,0);
    gap = false(n,1);
    for z = 1:numel(Segmentation.(name))
        summary = Segmentation.(name)(z).summary_stats;
        gap = gap | QC.(name).planes(z).frames.gap_before;
        if ~isfield(summary,'avgTCs') || isempty(summary.avgTCs), continue; end
        ids = summary.regionIDs(:);
        assert(isequal(size(summary.avgTCs),[numel(ids),n]) && numel(unique(ids))==numel(ids), ...
            'Invalid PCA trace mapping for %s plane %d.',name,z);
        % A region with no usable baseline in this trial cannot provide a shared feature.
        usable = any(isfinite(summary.avgTCs),2);
        keys{k} = [keys{k}; repmat(z,nnz(usable),1),ids(usable)];
        movies{k} = [movies{k},summary.avgTCs(usable,:)'];
    end
    if k==1
        shared = keys{k};
    else
        shared = intersect(shared,keys{k},'rows','stable');
    end
    frameInfo{k} = table(repmat(k,n,1),repmat(string(name),n,1),(1:n)', ...
        mean(SET.(name).relativeTime,1)',gap,'VariableNames', ...
        {'trial_index','trial_name','frame','time_s','gap_before'});
end
PCA.frames = vertcat(frameInfo{:});
if isempty(shared)
    PCA.status = 'No usable regions shared by all trials.';
    return
end

% Reorder every trial to the same feature map before pooling its frames.
for k = 1:numel(names)
    [~,columns] = ismember(shared,keys{k},'rows');
    movies{k} = movies{k}(:,columns);
end
X = vertcat(movies{:});
% Remove constant features first so their missing samples do not cost frames.
variable = std(X,0,1,'omitnan')>0;
X = X(:,variable);
shared = shared(variable,:);
complete = all(isfinite(X),2);
if isempty(shared) || nnz(complete)<2
    PCA.status = 'Insufficient complete frames or varying regions.';
    return
end

% Standardize across the pooled complete frames and fit by economy SVD.
% This gives the centered PCA scores without an additional toolbox.
X = X(complete,:);
mu = mean(X,1);
sigma = std(X,0,1);
vary = sigma>0;
if ~any(vary)
    PCA.status = 'No region varies on the complete frames.';
    return
end
shared = shared(vary,:);
PCA.center = mu(vary);
PCA.scale = sigma(vary);
Z = (X(:,vary)-PCA.center)./PCA.scale;
[U,S,V] = svd(Z,'econ');
singular = diag(S);
nPC = nnz(singular > max(size(Z))*eps(max(singular)));
PCA.coeff = V(:,1:nPC);
PCA.explained = 100*singular(1:nPC).^2/sum(singular.^2);
PCA.features = array2table(shared,'VariableNames',{'plane','region_id'});

% Keep all acquired frames in the output. Missing scores break trajectories.
PCA.frames.used = complete;
PCA.score = nan(height(PCA.frames),nPC);
PCA.score(complete,:) = U(:,1:nPC)*S(1:nPC,1:nPC);
PCA.status = 'complete';
end

function writeFramePCA(PCA,SET,folder)
% Save one score row per acquired frame plus the pooled trial trajectories.
scores = array2table(PCA.score,'VariableNames',cellstr(compose('PC%d',1:size(PCA.score,2))));
writetable([PCA.frames,scores],fullfile(folder,'frame_pca_scores.csv'));
if size(PCA.score,2)<2, return; end

% Use MATLAB's axes color order unless a BrewerMap palette was selected.
nTrials = numel(SET.trial_names_clean);
fig = figure('Visible','off','Color','w');
cleanup = onCleanup(@() deleteVideoFigure(fig)); %#ok<NASGU>
ax = axes(fig);
hold(ax,'on');
if ~isempty(SET.TrialColors)
    ax.ColorOrder = brewermap(nTrials,char(SET.TrialColors));
end
for k = 1:nTrials
    rows = PCA.frames.trial_index==k;
    xy = PCA.score(rows,1:2);
    % Insert a separator at acquisition gaps while keeping the next frame.
    gaps = PCA.frames.gap_before(rows);
    positions = (1:size(xy,1))' + cumsum(gaps);
    path = nan(size(xy,1)+nnz(gaps),2);
    path(positions,:) = xy;
    plot(ax,path(:,1),path(:,2),'.-', ...
        'DisplayName',SET.trial_names_clean{k});
end
xlabel(ax,sprintf('PC1 (%.1f%%)',PCA.explained(1)));
ylabel(ax,sprintf('PC2 (%.1f%%)',PCA.explained(2)));
title(ax,'Frame trajectories from segmented dF/F');
legend(ax,'Interpreter','none','Location','bestoutside');
axis(ax,'equal');
drawnow;
export_fig(fig,fullfile(folder,'frame_pca.pdf'),'-pdf','-painters');
end

function outputFolder = saveCRAPview(STACK, STACK_proc, Segmentation, SET, outputFolder, varargin)
%SAVECRAPVIEW Save one animal after dF/F calculation, before clearing arrays.
% saveCRAPview(STACK, STACK_proc, Segmentation, SET, outputFolder)
% Optional: 'SaveMoviesInMAT',false omits movies from results.mat. Both
% STACK and STACK_proc are ALWAYS exported to separate HDF5 files.
%
% STACK contains pixelwise dF/F in row-by-column-by-plane-by-frame order.
% STACK_proc contains dF/F calculated from the mean fluorescence of each
% region and repeated at every pixel in that region.
% Each trial/plane folder contains label and timing tables plus two traces:
% mean_pixel_dff.csv averages normalized pixels, while region_dff.csv
% reports the normalized region mean. Both use fractional dF/F.
% pixel_dff.h5 and region_dff.h5 store the complete movies. Trial MP4s and
% maximum PDFs are written inside each trial folder. Other summary PDFs,
% results.mat and metadata.json are written at the animal level.
% SET records the requested baseline and each trial's effective setting.
% Quality stores actual ROI baselines, frame QC, masks and reference images.
% Per-plane QC tables and manual-slice overlay/heatmap PDFs accompany the traces.
% On overwrite, the prior export is backed up until publication. COMPLETE.json
% is published after all current data files have been moved into place.

% Read the optional SaveMoviesInMAT argument. By default, results.mat also
% contains both movie arrays alongside the traces and segmentation.
parser = inputParser;
addParameter(parser,'SaveMoviesInMAT',true);
addParameter(parser,'Quality',struct());
addParameter(parser,'FramePCA',struct('status','disabled'));
parse(parser,varargin{:});
saveMovies = parser.Results.SaveMoviesInMAT;
Quality = parser.Results.Quality;
PCA = parser.Results.FramePCA;

% Resolve a bare animal output folder name against the current directory.
outputFolder = char(outputFolder);
[parentFolder,folderName] = fileparts(outputFolder);
assert(~isempty(folderName),'Specify an animal output folder, not a root directory.');
if isempty(parentFolder), parentFolder = pwd; end
outputFolder = fullfile(parentFolder,folderName);

% Create the destination if needed. Replacing existing exports requires SET.overwrite.
overwrite = isfield(SET,'overwrite') && SET.overwrite;
assert(~isfile(outputFolder),'Output path is an existing file.');
if ~isfolder(outputFolder), mkdir(outputFolder); end

% Hold an OS file lock through staging, publication, and cleanup. The OS
% releases it on process exit; the reusable lock file contains no data.
lockFile = java.io.RandomAccessFile(fullfile(outputFolder,'.CRAPview.lock'),'rw');
lockCleanup = onCleanup(@() lockFile.close()); %#ok<NASGU>
channel = lockFile.getChannel();
lock = channel.tryLock();
assert(~isempty(lock),'Another CRAPview export is active in %s.',outputFolder);

% Check MPEG-4 and PDF export support before writing trial data.
profiles = VideoWriter.getProfiles();
assert(any(strcmp({profiles.Name},'MPEG-4')), ...
    'This MATLAB installation does not support MPEG-4 video export.');
assert(exist('export_fig','file') ~= 0, 'Add export_fig to the MATLAB path.');

% Name both movies and the two PDF summaries for each trial.
trialNames = SET.trial_names_clean(:)';
namesWithSuffix = @(names,suffix) cellfun(@(name) [name suffix],names,'UniformOutput',false);
projectionNames = namesWithSuffix(trialNames,'_pixel_dff_std.pdf');
segmentationNames = namesWithSuffix(trialNames,'_segmentation.pdf');

% Publish only the current trials and format. Keep the completion marker
% first here so it can be backed up first and published last.
exportNames = [{'COMPLETE.json','results.mat','pixel_dff.h5','region_dff.h5','metadata.json'}, ...
    trialNames, projectionNames, segmentationNames];

% Publish the score table for every successful fit and a plot for rank >= 2.
if strcmp(PCA.status,'complete')
    exportNames{end+1} = 'frame_pca_scores.csv';
    if size(PCA.score,2)>=2, exportNames{end+1} = 'frame_pca.pdf'; end
end

% Include trials from the previous export when the current selection has
% changed. The saved PDF manifest has one field per exported trial.
knownTrials = trialNames;
previousMetadata = fullfile(outputFolder,'metadata.json');
if overwrite && isfile(previousMetadata)
    previous = jsondecode(fileread(previousMetadata));
    if isfield(previous,'format_version') && isfield(previous,'pdfs') && isstruct(previous.pdfs)
        knownTrials = union(trialNames,fieldnames(previous.pdfs)','stable');
    end
end

% Back up recognized current and legacy outputs, including entire trial
% folders. Moving each folder also retires its obsolete per-plane CSVs.
backupNames = [exportNames, {'stacks.h5','stacks_proc.h5','frame_pca_scores.csv','frame_pca.pdf'}, knownTrials];
for suffix = {'.mp4','_dff.mp4','_std_projection.pdf','_segmentation.pdf', ...
        '_pixel_dff.mp4','_region_dff.mp4','_pixel_dff_outlines.mp4','_pixel_dff_std.pdf','_fluorescence_max.pdf'}
    backupNames = [backupNames, namesWithSuffix(knownTrials,suffix{1})];
end
backupNames = unique(backupNames,'stable');
existing = cellfun(@(name) isfile(fullfile(outputFolder,name)) || ...
    isfolder(fullfile(outputFolder,name)), backupNames);
assert(~any(existing) || overwrite, ...
    'Exports already exist. Set SET.overwrite=true to replace them.');
% Build the complete export in a temporary folder before moving any existing results.
[~,transaction] = fileparts(tempname(outputFolder));
transaction = fullfile(outputFolder,['CRAPview_tmp_' transaction]);
stagingFolder = [transaction '_staging'];
mkdir(stagingFolder);

% Collect per-plane traces for results.mat as each trial is exported.
Traces = struct();

% Record the settings and export conventions so readers can interpret the
% CSV units and recover the MATLAB axis order from the HDF5 datasets.
metadata.format_version = 5;
metadata.segmentation_avgTCs = ['results.mat: Segmentation.(trial)(plane).summary_stats.avgTCs ' ...
    'contains fractional dF/F of each segmentation trace. Rows follow regionIDs; ' ...
    'avgTCs_F0 is the fluorescence baseline used for each row.'];
metadata.matlab_release = version('-release');
metadata.toolbox_versions = ver;
metadata.created_utc = char(datetime('now','TimeZone','UTC', ...
    'Format',"yyyy-MM-dd'T'HH:mm:ss'Z'"));
metadata.settings = jsonSafe(SET);
metadata.csv_matrix_orientation = 'rows=regions, columns=timepoints; no header';
metadata.labels_orientation = 'rows=image rows, columns=image columns; no header';
metadata.time_units = 'seconds';
metadata.dff_units = 'fraction, not percent';
metadata.baseline_qc = 'F0 and finite-sample counts are computed during normalization. Minimum absolute F0 is the larger of the configured absolute and relative floors.';
metadata.dff_formula = '(F - F0) / abs(F0); unusable F0 and excluded frames are NaN';
metadata.quality = 'results.mat Quality contains registration references, native-plane QC, and measured baseline diagnostics.';
metadata.roi_fluorescence = 'roi_fluorescence.csv contains F entering normalization.';
metadata.frame_qc = 'Original acquisition slots are retained. Excluded frames are NaN. Gaps split temporal filtering.';
metadata.registration_mask = 'Common measured support over frames; excludes affine fill and conservative nonrigid margins.';
metadata.pixel_dff = 'STACK: normalize each pixel using its own fluorescence baseline.';
metadata.mean_pixel_dff = 'mean_pixel_dff.csv: average STACK over the pixels of each label, omitting NaNs.';
metadata.region_dff = 'region_dff.csv: normalize the region-mean fluorescence using its own baseline (STACK_proc).';
metadata.background = 'ID 0 included when present; averaged within each plane/trial';
metadata.hdf5_matlab_axes = {'row','column','plane','time'};
metadata.hdf5_raw_axes = {'time','plane','column','row'};
metadata.hdf5_python = 'h5py dataset[:].transpose(3,2,1,0) restores MATLAB axis order';
metadata.timestamp_note = 'Projection timestamps average the selected planes. Original retained-plane times are exported separately.';
% settings.dFF_type and settings.dFF_value describe the request. Each
% settings.(trialName).dFF_value records the value used by the main block.

% Export each trial and plane; trace-row mapping includes background ID 0.
for trialIndex = 1:numel(trialNames)
    trialName = trialNames{trialIndex};
    trialFolder = fullfile(stagingFolder,trialName);
    mkdir(trialFolder);

    % Check that both dF/F products share a grid and that each plane has
    % one absolute and one relative acquisition time per frame.
    trial = STACK.(trialName);
    processed = STACK_proc.(trialName);
    assert(isequal(size(trial),size(processed)), ...
        'STACK and STACK_proc sizes differ for %s.',trialName);
    numberOfFrames = size(trial,4);
    planeTitles = exportPlaneTitles(SET,size(trial,3));
    trialSettings = SET.(trialName);
    assert(isequal(size(trialSettings.relativeTime),[size(trial,3),numberOfFrames]) && ...
        isequal(size(trialSettings.absoluteTime),[size(trial,3),numberOfFrames]), ...
        'Timestamp dimensions do not match trial %s.',trialName);

    % Give each plane its own label image, region traces and timestamps.
    for planeIndex = 1:size(trial,3)
        planeFolder = fullfile(trialFolder,sprintf('plane_%03d',planeIndex));
        mkdir(planeFolder);

        % Require one nonnegative integer region label per image pixel.
        labels = Segmentation.(trialName)(planeIndex).pockets_labeled;
        assert(isequal(size(labels),[size(trial,1),size(trial,2)]) && ...
            all(isfinite(labels(:))) && all(labels(:) >= 0) && ...
            all(labels(:) == fix(labels(:))), 'Invalid label image for %s.',trialName);
        regionIDs = unique(labels(:));
        numberOfRegions = numel(regionIDs);
        % Flatten each frame in the same pixel order as labels(:). Each trace column is one frame.
        pixelTraces = reshape(trial(:,:,planeIndex,:),[],numberOfFrames);
        processedTraces = reshape(processed(:,:,planeIndex,:),[],numberOfFrames);

        % Allocate one row per label, including background when present.
        meanPixelDff = nan(numberOfRegions,numberOfFrames,'like',trial);
        regionDff = nan(numberOfRegions,numberOfFrames,'like',processed);
        pixelCounts = zeros(numberOfRegions,1);
        validSpatial = true(size(labels));
        if isfield(SET,'STACK_mask'), validSpatial = SET.STACK_mask.(trialName)(:,:,planeIndex); end

        % Average normalized pixels for the first trace. The second movie
        % already contains the normalized region mean at each labeled pixel.
        for regionIndex = 1:numberOfRegions
            pixels = labels(:) == regionIDs(regionIndex);
            meanPixelDff(regionIndex,:) = mean(pixelTraces(pixels,:),1,'omitnan');
            regionDff(regionIndex,:) = mean(processedTraces(pixels,:),1,'omitnan');
            pixelCounts(regionIndex) = nnz(pixels & validSpatial(:));
        end

        % Names and slice indices are optional metadata from manualSliceSeg.
        roiNames = repmat({''},numberOfRegions,1);
        sliceIndices = nan(numberOfRegions,1);
        sourceSummary = Segmentation.(trialName)(planeIndex).summary_stats;
        if isscalar(sourceSummary) && isfield(sourceSummary,'roiIndex')
            summaryIDs = (1:numel(sourceSummary.roiIndex))';
            if isfield(sourceSummary,'regionIDs'), summaryIDs = sourceSummary.regionIDs; end
            [present,summaryRows] = ismember(regionIDs,summaryIDs);
            for regionIndex = find(present(:))'
                row = summaryRows(regionIndex);
                roiNames{regionIndex} = sourceSummary.roiNames{sourceSummary.roiIndex(row)};
                sliceIndices(regionIndex) = sourceSummary.sliceIndex(row);
            end
        end
        roiNames(regionIDs==0) = {'background'};
        % Use trace_row in regions.csv to look up a region in mean_pixel_dff.csv and region_dff.csv.
        % The frame column in imaging_times.csv identifies the corresponding trace column.
        regions = table((1:numberOfRegions)',regionIDs,pixelCounts,roiNames,sliceIndices, ...
            'VariableNames',{'trace_row','region_id','pixel_count','roi_name','slice_index'});
        timing = table((1:numberOfFrames)',trialSettings.relativeTime(planeIndex,:)', ...
            trialSettings.absoluteTime(planeIndex,:)', ...
            'VariableNames',{'frame','relative_time_s','absolute_time_s'});

        % Write the label image and the tables used to interpret both trace matrices.
        writematrix(labels,fullfile(planeFolder,'labels.csv'));
        writetable(regions,fullfile(planeFolder,'regions.csv'));
        writematrix(meanPixelDff,fullfile(planeFolder,'mean_pixel_dff.csv'));
        writematrix(regionDff,fullfile(planeFolder,'region_dff.csv'));
        writetable(timing,fullfile(planeFolder,'imaging_times.csv'));

        % Store the same row mapping and time base with the MATLAB trace arrays.
        Traces.(trialName)(planeIndex).regions = regions;
        Traces.(trialName)(planeIndex).mean_pixel_dff = meanPixelDff;
        Traces.(trialName)(planeIndex).region_dff = regionDff;
        Traces.(trialName)(planeIndex).imaging_times = timing;

        % Save the frame ledger, measured fluorescence and F0 alongside the
        % normalized traces, using the same trace rows and frame numbers.
        if isfield(Quality,trialName)
            q = Quality.(trialName).planes(planeIndex);
            writetable(q.frames,fullfile(planeFolder,'frame_qc.csv'));
            writetable(q.baselines,fullfile(planeFolder,'baseline_qc.csv'));
            writeJSON(fullfile(planeFolder,'pixel_baseline_summary.json'),q.pixelBaselineSummary);
            writematrix(q.fluorescence,fullfile(planeFolder,'roi_fluorescence.csv'));
            writematrix(q.pixelBaselineValid,fullfile(planeFolder,'pixel_baseline_valid.csv'));
            writematrix(SET.STACK_mask.(trialName)(:,:,planeIndex),fullfile(planeFolder,'registration_valid.csv'));
            if strcmp(SET.segmentation_method,'manualSliceSeg')
                writeSliceQC(q,labels,regions,regionDff,trialFolder,trialName,planeIndex,planeTitles{planeIndex},SET.colmap);
            end
        end
    end

    % Trace geometry once per trial and reuse it across PDFs and video frames.
    boundaries = cell(1,size(trial,3));
    if ~isempty(SET.segmentation_method)
        for z = 1:numel(boundaries)
            boundaries{z} = regionEdges(Segmentation.(trialName)(z).pockets_labeled);
        end
    end
    planeQC = [];
    if isfield(Quality,trialName), planeQC = Quality.(trialName).planes; end
    metadata.pdfs.(trialName) = writeTrialPDFs(trial,processed,Segmentation.(trialName), ...
        planeQC,boundaries,SET,stagingFolder,trialName,planeTitles);

    if isfield(Quality,trialName) && strcmp(SET.segmentation_method,'manualSliceSeg')
        metadata.pdfs.(trialName).slice_qc = [trialName '/slice_qc.pdf'];
    end

    % Both MP4s use the same time base and plane labels. Only the pixelwise
    % movie overlays segmentation boundaries. Paths in metadata are relative.
    pixelVideo = [trialName '/' trialName '_pixel_dff.mp4'];
    regionVideo = [trialName '/' trialName '_region_dff.mp4'];
    metadata.pixel_dff_videos.(trialName) = writeTrialVideo(trial, ...
        trialSettings.relativeTime,fullfile(stagingFolder,pixelVideo), ...
        SET,'Pixelwise dF/F (fraction)','STACK',boundaries,planeTitles);
    metadata.pixel_dff_videos.(trialName).filename = pixelVideo;
    metadata.region_dff_videos.(trialName) = writeTrialVideo(processed, ...
        trialSettings.relativeTime,fullfile(stagingFolder,regionVideo), ...
        SET,'Region dF/F (fraction)','STACK_proc',cell(size(boundaries)),planeTitles);
    metadata.region_dff_videos.(trialName).filename = regionVideo;

    % Combine rising and falling trigger edges into one timeline. Trials without edges get an empty event table.
    voltage = struct('risingTime',[],'fallingTime',[]);
    if isfield(trialSettings,'voltage'), voltage = trialSettings.voltage; end
    eventTimes = [voltage.risingTime(:); voltage.fallingTime(:)];
    eventTypes = [repmat({'rising'},numel(voltage.risingTime),1); ...
        repmat({'falling'},numel(voltage.fallingTime),1)];
    events = table(eventTypes,eventTimes,'VariableNames',{'event_type','time_s'});
    events = sortrows(events,'time_s');
    writetable(events,fullfile(trialFolder,'voltage_events.csv'));
    % Optional full waveform: populate these fields while loading the CSV.
    if isfield(voltage,'time') && isfield(voltage,'values')
        waveform = table(voltage.time(:),voltage.values(:), ...
            'VariableNames',{'time_s','voltage'});
        writetable(waveform,fullfile(trialFolder,'voltage_waveform.csv'));
    end
    % For projected movies, also export the acquisition time of each plane before projection.
    if isfield(trialSettings,'relativeTime_planes')
        originalRelative = trialSettings.relativeTime_planes;
        originalAbsolute = trialSettings.absoluteTime_planes;
        [planeNumbers,frameNumbers] = ndgrid(1:size(originalRelative,1),1:numberOfFrames);
        originalTiming = table(planeNumbers(:),frameNumbers(:), ...
            originalRelative(:),originalAbsolute(:), ...
            'VariableNames',{'plane_before_projection','frame','relative_time_s','absolute_time_s'});
        writetable(originalTiming,fullfile(trialFolder,'imaging_times_before_projection.csv'));
    end
end

% Save both movie collections, independently of SaveMoviesInMAT.
writeStackHDF5(fullfile(stagingFolder,'pixel_dff.h5'), STACK, 'STACK', ...
    metadata.pixel_dff, metadata.dff_units);
writeStackHDF5(fullfile(stagingFolder,'region_dff.h5'), STACK_proc, 'STACK_proc', ...
    'dF/F of region-mean fluorescence, repeated across the labeled pixels.', metadata.dff_units);

% Index movie files and their trial datasets for readers of metadata.json.
metadata.hdf5_stack_fields = fieldnames(STACK);
metadata.hdf5_stack_proc_fields = fieldnames(STACK_proc);
metadata.hdf5_stack_file = 'pixel_dff.h5';
metadata.hdf5_stack_proc_file = 'region_dff.h5';
metadata.movies_in_mat = saveMovies;

% Publish the pooled analysis with the same completion marker as the movies.
metadata.frame_pca_status = PCA.status;
if strcmp(PCA.status,'complete')
    writeFramePCA(PCA,SET,stagingFolder);
end
writeJSON(fullfile(stagingFolder,'metadata.json'),metadata);

% Save traces and settings for MATLAB users, optionally including the movies.
matFile = fullfile(stagingFolder,'results.mat');
if saveMovies
    save(matFile,'SET','Segmentation','Traces','Quality','PCA','STACK','STACK_proc','metadata','-v7.3');
else
    save(matFile,'SET','Segmentation','Traces','Quality','PCA','metadata','-v7.3');
end
% Stage the completion marker only after all data and metadata writes succeed.
writeJSON(fullfile(stagingFolder,'COMPLETE.json'), ...
    struct('complete',true,'created_utc',metadata.created_utc,'trial_count',numel(trialNames)));

% All temporary files and backups remain inside outputFolder.
backupFolder = '';
% Record each successful move so a failed publication can unwind those moves in reverse order.
backedUp = {};
promoted = {};
try
    if any(existing)
        backupFolder = [transaction '_previous'];
        mkdir(backupFolder);
        % Remove the previous completion marker before changing any data.
        for index = find(existing)
            name = backupNames{index};
            [ok,message] = movefile(fullfile(outputFolder,name),fullfile(backupFolder,name));
            assert(ok,'%s',message);
            backedUp{end+1} = name;
        end
    end
    % Publish the new completion marker LAST.
    publishNames = [exportNames(2:end), exportNames(1)];
    for index = 1:numel(publishNames)
        name = publishNames{index};
        [ok,message] = movefile(fullfile(stagingFolder,name),fullfile(outputFolder,name));
        assert(ok,'%s',message);
        promoted{end+1} = name;
    end
catch exception
    % Move new files back to staging, then restore old files and marker.
    for index = numel(promoted):-1:1
        name = promoted{index};
        [ok,message] = movefile(fullfile(outputFolder,name),fullfile(stagingFolder,name));
        if ~ok, warning('Rollback failed for %s: %s',name,message); end
    end
    for index = numel(backedUp):-1:1
        name = backedUp{index};
        [ok,message] = movefile(fullfile(backupFolder,name),fullfile(outputFolder,name));
        if ~ok, warning('Restore failed for %s: %s',name,message); end
    end
    rethrow(exception)
end
% Only retire temporary exports after COMPLETE.json has been published.
% Recognize this exporter's namespace and legacy MATLAB tempname folders.
if overwrite
    entries = dir(outputFolder);
    for index = find([entries.isdir])
        name = entries(index).name;
        owned = ~isempty(regexp(name,'^CRAPview_tmp_[A-Za-z0-9_-]+_(staging|previous)$','once'));
        legacy = ~isempty(regexp(name,'^tp[0-9a-fA-F-]+_(staging|previous)$','once'));
        if ~owned && ~legacy, continue; end
        candidate = fullfile(outputFolder,name);
        candidateFile = java.io.File(candidate);
        if java.nio.file.Files.isSymbolicLink(candidateFile.toPath()), continue; end
        if legacy
            % Old folders had no CRAPview prefix. Check their contents before
            % removing a directory that happens to match MATLAB's temp name.
            content = dir(candidate);
            items = setdiff({content.name},{'.','..'});
            if ~all(ismember(items,backupNames) | startsWith(items,'TSeries')), continue; end
        end
        rmdir(candidate,'s');
    end
end
fprintf('Saved: %s\n',outputFolder);
end

function writeJSON(filename,value)
fileID = fopen(filename,'w','n','UTF-8');
assert(fileID~=-1,'Cannot open %s.',filename);
cleanup = onCleanup(@() fclose(fileID)); %#ok<NASGU>
count = fprintf(fileID,'%s\n',jsonencode(value));
assert(count>=0,'Cannot write %s.',filename);
[message,errorNumber] = ferror(fileID);
assert(errorNumber==0,'%s',message);
end

function value = jsonSafe(value)
% Settings may include custom function handles, which JSON cannot encode.
if isa(value,'function_handle')
    value = func2str(value);
elseif isstruct(value)
    names = fieldnames(value);
    for index = 1:numel(value)
        for nameIndex = 1:numel(names)
            value(index).(names{nameIndex}) = jsonSafe(value(index).(names{nameIndex}));
        end
    end
elseif iscell(value)
    value = cellfun(@jsonSafe,value,'UniformOutput',false);
end
end

function videoInfo = writeTrialVideo(movie, relativeTime, filename, SET, color_label, source, boundaries, planeTitles)
% Use the median volume interval for playback and recorded times for frame titles.
numberOfPlanes = size(movie,3);
numberOfFrames = size(movie,4);
frameTimes = mean(relativeTime,1);
if numberOfFrames > 1
    intervals = diff(frameTimes);
    assert(all(isfinite(intervals)) && all(intervals > 0), ...
        'Video timestamps must be finite and strictly increasing.');
    frameRate = 1 / median(intervals);
else
    frameRate = 1;
end
% Estimate each plane's 1st/99th percentiles across space and time.
% Compute once so that brightness does not rescale between frames.
limits = zeros(numberOfPlanes,2);
for planeIndex = 1:numberOfPlanes
    planeMovie = movie(:,:,planeIndex,:);
    stride = max(1,ceil(numel(planeMovie)/1e6));
    samples = planeMovie(1:stride:end);
    samples = samples(isfinite(samples));
    if ~isempty(samples)
        samples = quantile(samples(:),[0.01 0.99]);
    end
    limits(planeIndex,:) = symmetricLimits(samples);
end
clear planeMovie samples

figureHandle = figure('Color','w','Units','normalized', ...
    'Position',[0 0 1 1],'Resize','off','MenuBar','none','ToolBar','none');
figureCleanup = onCleanup(@() deleteVideoFigure(figureHandle)); %#ok<NASGU>
layout = tiledlayout(figureHandle,'flow','TileSpacing','compact','Padding','compact');
imageHandles = gobjects(numberOfPlanes,1);
for planeIndex = 1:numberOfPlanes
    axesHandle = nexttile(layout);
    imageHandles(planeIndex) = imagesc(axesHandle,movie(:,:,planeIndex,1),limits(planeIndex,:));
    axis(axesHandle,'image');
    axis(axesHandle,'off');
    % These lines stay fixed while only the image CData changes each frame.
    drawRegionEdges(axesHandle,boundaries{planeIndex});
    title(axesHandle,planeTitles{planeIndex});
    colorbarHandle = colorbar(axesHandle);
    colorbarHandle.Label.String = color_label;
end
colormap(figureHandle, SET.colmap);
video = VideoWriter(filename,'MPEG-4');
video.FrameRate = frameRate;
video.Quality = 95;
open(video);
videoCleanup = onCleanup(@() close(video));
for frameIndex = 1:numberOfFrames
    for planeIndex = 1:numberOfPlanes
        imageHandles(planeIndex).CData = movie(:,:,planeIndex,frameIndex);
    end
    title(layout,sprintf('Time: %.2f s | Frame %d/%d', ...
        frameTimes(frameIndex),frameIndex,numberOfFrames));
    drawnow;
    writeVideo(video,getframe(figureHandle));
end
clear videoCleanup % Finalize the MP4 before publishing the export.
[~,videoName,extension] = fileparts(filename);
videoInfo.filename = [videoName extension];
videoInfo.source = source;
videoInfo.segmentation_outlines = any(~cellfun(@isempty,boundaries));
videoInfo.units = 'fractional dF/F';
videoInfo.color_limits = limits; % One row [lower upper] per plane.
videoInfo.color_limits_method = 'Symmetric about zero using the larger absolute sampled 1st/99th percentile per plane, fixed across frames.';
videoInfo.frame_rate_hz = frameRate;
videoInfo.frame_count = numberOfFrames;
videoInfo.timing = 'Constant-rate playback using median volume interval; title shows recorded time.';
end

function deleteVideoFigure(figureHandle)
if isgraphics(figureHandle), delete(figureHandle); end
end
function edges = regionEdges(labels)
% Trace positive labels individually to retain shared edges, holes and
% disconnected components. NaN separators keep unrelated contours apart.
ids = unique(labels(labels>0));
parts = cell(numel(ids),1);
for i = 1:numel(ids)
    contours = bwboundaries(labels==ids(i),8,'TraceStyle','pixeledge');
    contours = cellfun(@(rc) [rc; rc(1,:); NaN NaN],contours,'UniformOutput',false);
    parts{i} = vertcat(contours{:});
end
edges = vertcat(parts{:});
end

function drawRegionEdges(ax,edges)
% Boundary coordinates are (row,column); plot in image (x,y) coordinates.
if isempty(edges), return; end
hold(ax,'on');
plot(ax,edges(:,2),edges(:,1),'w','LineWidth',0.5);
end

function titles = exportPlaneTitles(SET,n)
% Compression selections are indexed in the retained stack, as in compressPlanes.
titles = arrayfun(@(z) sprintf('Plane %d',z),1:n,'UniformOutput',false);
if ~SET.max_compression, return; end
planes = SET.max_compression_planes(:)';
assert(n==1 && ~isempty(planes),'Expected one compressed plane.');
if isscalar(planes)
    titles = {sprintf('Plane %d',planes)};
elseif all(diff(planes)==1)
    titles = {sprintf('Planes %d:%d',planes(1),planes(end))};
else
    titles = {['Planes ' strjoin(cellstr(string(planes)),', ')]};
end
end

function pdfInfo = writeTrialPDFs(trial,processed,segmentation,q,boundaries,SET,folder,trialName,planeTitles)
% Each PDF has one tile per output plane. Only the segmentation view adds IDs.
pdfInfo.std_projection = [trialName '_pixel_dff_std.pdf'];
pdfInfo.segmentation = [trialName '_segmentation.pdf'];
pdfInfo.std_source = 'Temporal sample SD of pixelwise dF/F, omitting NaNs';
sd = std(trial,0,4,'omitnan');
pdfInfo.std_color_limits = writePlanePDF(sd,boundaries,[],SET.colmap,folder, ...
    pdfInfo.std_projection,trialName,'Temporal SD of pixelwise dF/F',planeTitles);
pdfInfo.std_color_limits_method = 'Symmetric about zero using the largest absolute finite value per plane.';
pdfInfo.std_colormap = jsonSafe(SET.colmap);

% Show anatomical labels on unbinned registered fluorescence when available.
if isstruct(q) && isfield(q,'meanImage')
    anatomy = cat(3,q.meanImage);
    units = 'Mean registered fluorescence';
else
    anatomy = mean(trial,4,'omitnan');
    units = 'Mean pixelwise dF/F';
end
if isempty(SET.segmentation_method), segmentation = []; end
pdfInfo.segmentation_color_limits = writePlanePDF(anatomy,boundaries,segmentation,SET.colmap,folder, ...
    pdfInfo.segmentation,trialName,units,planeTitles);
pdfInfo.segmentation_source = units;

% Collapse only the time dimension of each normalized movie. Frame
% exclusions and unusable baselines are already represented by NaNs.
pdfInfo.pixel_max_projection = [trialName '/' trialName '_pixel_dff_max.pdf'];
pdfInfo.region_max_projection = [trialName '/' trialName '_region_dff_max.pdf'];
pdfInfo.pixel_max_color_limits = writePlanePDF(max(trial,[],4,'omitnan'), ...
    boundaries,[],SET.colmap,folder,pdfInfo.pixel_max_projection,trialName, ...
    'Temporal maximum of pixelwise dF/F',planeTitles);
pdfInfo.region_max_color_limits = writePlanePDF(max(processed,[],4,'omitnan'), ...
    cell(size(boundaries)),[],SET.colmap,folder,pdfInfo.region_max_projection,trialName, ...
    'Temporal maximum of region dF/F',planeTitles);
end

function limits = symmetricLimits(values)
% Center the color scale on zero, even for one-sided or constant images.
finiteValues = values(isfinite(values));
extent = max(abs(finiteValues(:)));
if isempty(extent) || extent==0, extent = 1; end
limits = [-extent extent];
end

function limits = writePlanePDF(images,boundaries,labelPlanes,cmap,folder,filename,trialName,units,planeTitles)
% Draw intensity and geometric overlays on the same pixel coordinates.
n = size(images,3);
cols = ceil(sqrt(n));
fig = figure('Color','w','Visible','off','Units','pixels','Position',[100 100 1200 800]);
cleanup = onCleanup(@() deleteVideoFigure(fig)); %#ok<NASGU>
layout = tiledlayout(fig,ceil(n/cols),cols,'TileSpacing','compact','Padding','compact');
limits = zeros(n,2);
for z = 1:n
    ax = nexttile(layout);
    limits(z,:) = symmetricLimits(images(:,:,z));
    im = imagesc(ax,images(:,:,z),limits(z,:));
    im.AlphaData = isfinite(images(:,:,z));
    axis(ax,'image'); axis(ax,'off');
    drawRegionEdges(ax,boundaries{z});
    if ~isempty(labelPlanes)
        labels = labelPlanes(z).pockets_labeled;
        ids = unique(labels(labels>0));
        if numel(ids)<=100
            for id = ids(:)'
                [rows,colsInROI] = find(labels==id);
                text(ax,mean(colsInROI),mean(rows),num2str(id),'Color','w','HorizontalAlignment','center');
            end
        end
    end
    title(ax,planeTitles{z});
    cb = colorbar(ax); cb.Label.String = units;
end
colormap(fig,cmap);
title(layout,[trialName ' | ' units],'Interpreter','none');
drawnow;
try
    export_fig(fig,fullfile(folder,filename),'-pdf','-painters');
catch
    exportgraphics(fig,fullfile(folder,filename),'ContentType','vector');
    warning('Saving figure using export_fig() failed. Used exportgraphics() instead.')
end
end

function writeStackHDF5(filename, stacks, groupName, processingNote, units)
% Preserve every field's values, datatype, and four-dimensional shape.
stackNames = fieldnames(stacks);
for stackIndex = 1:numel(stackNames)
    name = stackNames{stackIndex};
    data = stacks.(name);
    assert(isnumeric(data) && isreal(data) && ~issparse(data) && ...
        ~isempty(data) && ndims(data)<=4, ...
        '%s.%s must be a real, full numeric movie.',groupName,name);
    dimensions = [size(data,1),size(data,2),size(data,3),size(data,4)];
    dataset = ['/' groupName '/' name];
    h5create(filename,dataset,dimensions,'Datatype',class(data), ...
        'ChunkSize',min(dimensions,[64 64 1 16]),'Deflate',4);
    h5write(filename,dataset,data);
    h5writeatt(filename,dataset,'matlab_size',dimensions);
    h5writeatt(filename,dataset,'matlab_axis_order','row,column,plane,time');
    h5writeatt(filename,dataset,'raw_hdf5_axis_order','time,plane,column,row');
    h5writeatt(filename,dataset,'matlab_class',class(data));
    h5writeatt(filename,dataset,'processing_note',processingNote);
    h5writeatt(filename,dataset,'units',units);
end
end

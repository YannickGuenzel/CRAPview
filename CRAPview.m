%% CRAPview
% Process PrairieView two-photon imaging trials: load a selected channel
% and acquisition timestamps, optionally correct motion, filter images,
% segment ROIs, and calculate region-averaged fluorescence and dF/F.
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
% Version: 24-Sep-2026 | (R2024a)

clear all; close all; clc
delete(gcp('nocreate'))
parpool("Threads");

%% Settings

% Imaging channel required in each selected TIFF filename (Ch2 = green).
SET.Channel = 'Ch2';

% Path to GitHub folder
SET.GithubPath = '...';

% Volumetric data with a piezo can result in the first plane being off.
% This setting allows you to remove it.
SET.dropTop = true;

% Set whether to correct for motion using NoRMCorre with standard settings.
SET.CorrectMotion = true;
% Set whether to process trials together. Alternatively, trial one can be
% used as an template. Or all trials are corrected separately.
SET.CorrectMotion_pool = 'together';                                       % 'together' or 'template' or 'separate'
% Set for how may iterations NoRMCorre should run
SET.NoRMCorre_iter = 10;
% If the data is 3D, i.e., a volume over time, set whether the motion
% correction should be done per plane (2D) or applied to the whole volume
% at once (3D; this requires a lot of memory)
SET.NoRMCorre_dim = '2D';                                                  % '2D' or '3D'
% Add pixels on every XY edge for padding
SET.NoRMCorre_padding = 0;

% Set the standard deviation for 2D Gaussian filtering ('gauss'), box
% size for 2D median filtering ('med'), or both [box, std] for
% both ('med-gauss'), or vice versa for 'gauss-med'
SET.SmoothData_spat_type = 'med-gauss';                                    % 'med' or 'gauss' or 'med-gauss' or 'gauss-med'
SET.SmoothData_spat = [3 1];

% Set whether to apply temporal filtering and which method to use.
% Available approaches are: movmean and movmedian. Specify a window length
% in frames. Set SmoothData_temp_type=[]; to skip temporal smoothing
SET.SmoothData_temp_type = 'movmedian';                                    % 'movmean' or 'movmedian'
SET.SmoothData_temp = 3;

% Set whether the individual planes of a volume should be compressed to a
% single plane using a maximum projection
SET.max_compression = false;

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
SET.dFF_type = 'quantile';                                                   % 'window' or 'quantile'
SET.dFF_value = 0.05;

% Set whether to re-run already procesed data
SET.overwrite = true;

%% CalciSeg segmentation settings

SET.segmentation_settings = struct();
if strcmp(SET.segmentation_method, 'CalciSeg')
    % Choose custom CalciSeg setting here. See its documentation for
    % details.
    SET.segmentation_settings.quiet = false;
    SET.segmentation_settings.projection_method = 'std';
    SET.segmentation_settings.init_seg_method = 'voronoi';
    SET.segmentation_settings.n_rep = 1;
    SET.segmentation_settings.refinement_method = 'corr';
    SET.segmentation_settings.detrend = 'linear';
    SET.segmentation_settings.limitPixCount = [25 inf];
    SET.segmentation_settings.corr_thresh = 0.95;
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

% Set a nice colormap for saving
SET.colmap = brewermap(1000, 'RdPu');

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
% Check whether everything is in order
CheckFolderStructure(SET, curr)

% Iterate over all animals
for iAni = 1:size(curr.dir.all, 1)
    clearvars -except iAni curr rawTraces SET Batch_Info iBatch
    % Check whether this is what we are looking for, i.e. whether the
    % string "Animal" is present
    if contains(curr.dir.all(iAni).name, 'Animal') && curr.dir.all(iAni).isdir
        % Process each animal in its own try/catch so one bad dataset only skips
        % that animal instead of aborting the whole batch.
        try
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
            if SET.overwrite || ~isfolder(fullfile(SET.path2animal, curr.dir.all(iAni).name, '02_Data_Processed'))


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
                end%iTrial


                % Correct motion
                % ---------------------------------------------------------
                if SET.CorrectMotion
                    STACK = correctMotion(STACK, SET);
                end%if correct motion


                % Filter images (spatial and then temporal)
                % ---------------------------------------------------------
                STACK = filterImages(STACK, SET);

                % Compress planes using a maximum intensity compression
                if SET.max_compression
                    for iTrial = 1:SET.N
                        trialName = SET.trial_names_clean{iTrial};
                        STACK.(trialName) = max(STACK.(trialName), [], 3);
                        % Keep original plane times; a projected volume has no
                        % single exact acquisition time. Use their mean as its reference.
                        SET.(trialName).relativeTime_planes = SET.(trialName).relativeTime;
                        SET.(trialName).absoluteTime_planes = SET.(trialName).absoluteTime;
                        SET.(trialName).n_planes_before_compression = SET.(trialName).n_planes;
                        SET.(trialName).relativeTime = mean(SET.(trialName).relativeTime, 1);
                        SET.(trialName).absoluteTime = mean(SET.(trialName).absoluteTime, 1);
                        SET.(trialName).n_planes = 1;
                        SET.(trialName).DataDimensionality = 2;
                    end%iTrial
                    SET.DataDimensionality = 2;
                end%if compress


                % Segment data
                % ---------------------------------------------------------
                [STACK_proc, Segmentation] = segmentImages(STACK, SET);


                % Calculate the relative change over baseline, dFF
                % ---------------------------------------------------------
                for iTrial = 1:SET.N
                    trialName = SET.trial_names_clean{iTrial};
                    numberOfFrames = size(STACK_proc.(trialName), 4);
                    if strcmp(SET.dFF_type, 'window')
                        baselineWindow = SET.dFF_value;
                        validWindow = isnumeric(baselineWindow) && isreal(baselineWindow) && ...
                            numel(baselineWindow) == 2 && all(isfinite(baselineWindow(:))) && ...
                            all(baselineWindow(:) == fix(baselineWindow(:))) && ...
                            baselineWindow(1) >= 1 && baselineWindow(2) <= numberOfFrames && ...
                            baselineWindow(1) <= baselineWindow(2);
                        if ~validWindow
                            baselineWindow = [1 numberOfFrames];
                        end
                        % Store the actual window per trial; keep the requested global setting.
                        SET.(trialName).dFF_value = baselineWindow;
                        BL = mean(STACK_proc.(trialName)(:,:,:,baselineWindow(1):baselineWindow(2)), 4);
                    elseif strcmp(SET.dFF_type, 'quantile')
                        SET.(trialName).dFF_value = SET.dFF_value;
                        BL = quantile(STACK_proc.(trialName), SET.dFF_value, 4);
                    else
                        error('Unknown dFF_type: %s', SET.dFF_type);
                    end
                    STACK_proc.(trialName) = (STACK_proc.(trialName) - BL) ./ max(BL, eps('like', BL));
                end%iTrial


                % Store everything
                % ---------------------------------------------------------
                saveCRAPview(STACK, STACK_proc, Segmentation, SET,...
                    fullfile(SET.path2animal, curr.dir.all(iAni).name, '02_Data_Processed'));


            end%if overwrite
        catch ME
            warning('CRAPview:animalFailed', 'Skipping animal "%s": %s (%s)', ...
                curr.dir.all(iAni).name, ME.message, ME.identifier);
        end%try
    end%if animal
end%iAni


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
        snapshot = im2single(imread(fullfile(trialFolder, filename), page));
        if isempty(STACK)
            SET.(trialName).xy = [size(snapshot,1), size(snapshot,2)];
            SET.(trialName).channel = SET.Channel;
            STACK = nan([SET.(trialName).xy, SET.(trialName).n_planes, ...
                SET.(trialName).n_frames], 'single');
        end
        if numberOfCycles == 1
            STACK(:,:,1,frameIndex) = snapshot;
        else
            STACK(:,:,frameIndex,cycleIndex) = snapshot;
        end
    end
end
end%FCN:getStack

%% ------------------------------------------------------------------------

function STACK = correctMotion(STACK, SET)
% Trials must be X-by-Y-by-Z-by-time arrays (at least two timepoints).
% SET.CorrectMotion_pool: 'together', 'template', or 'separate'.
% SET.NoRMCorre_padding: pixels per side; scalar or [rows columns] (default 0).
% Padding replicates XY edges; no padding in Z/time. Outputs are cropped back.
% SET.NoRMCorre_dim: '2D' or '3D'. Outputs are single precision.

padding = 0;
if isfield(SET, 'NoRMCorre_padding')
    padding = SET.NoRMCorre_padding;
end
validateattributes(padding, {'numeric'}, ...
    {'vector','real','finite','integer','nonnegative'});
if isscalar(padding), padding = [padding padding]; end
assert(numel(padding) == 2, 'Padding must be a scalar or [rows columns].');
padding = double(padding(:)');

trialNames = SET.trial_names_clean;
trials = cell(size(trialNames));
originalSizes = zeros(numel(trialNames), 2);
for trialIndex = 1:numel(trialNames)
    trial = single(STACK.(trialNames{trialIndex}));
    originalSizes(trialIndex,:) = [size(trial,1), size(trial,2)];
    trials{trialIndex} = padarray(trial, [padding 0 0], 'replicate', 'both');
end

switch SET.CorrectMotion_pool
    case 'together'
        frameCounts = cellfun(@(trial) size(trial,4), trials);
        combinedStack = correctStack(cat(4, trials{:}), SET, []);
        firstFrame = 1;
        for trialIndex = 1:numel(trials)
            lastFrame = firstFrame + frameCounts(trialIndex) - 1;
            trials{trialIndex} = combinedStack(:,:,:,firstFrame:lastFrame);
            firstFrame = lastFrame + 1;
        end

    case 'template'
        trials{1} = correctStack(trials{1}, SET, []);
        reference = mean(trials{1}, 4, 'omitnan');
        for trialIndex = 2:numel(trials)
            trials{trialIndex} = correctStack(trials{trialIndex}, SET, reference);
        end

    case 'separate'
        for trialIndex = 1:numel(trials)
            trials{trialIndex} = correctStack(trials{trialIndex}, SET, []);
        end
end

for trialIndex = 1:numel(trials)
    rows = padding(1) + (1:originalSizes(trialIndex,1));
    columns = padding(2) + (1:originalSizes(trialIndex,2));
    STACK.(trialNames{trialIndex}) = trials{trialIndex}(rows,columns,:,:);
end
end%FCN:correctMotion

function stack = correctStack(stack, SET, reference)
numberOfRows = size(stack,1);
numberOfColumns = size(stack,2);
numberOfPlanes = size(stack,3);
numberOfFrames = size(stack,4);
use2D = strcmp(SET.NoRMCorre_dim, '2D');
registrationDepth = numberOfPlanes;
if use2D
    registrationDepth = 1;
end

options = NoRMCorreSetParms( ...
    'd1', numberOfRows, 'd2', numberOfColumns, 'd3', registrationDepth, ...
    'iter', SET.NoRMCorre_iter, 'print_msg', false, ...
    'use_parallel', true, 'upd_template', isempty(reference));

if use2D
    for planeIndex = 1:numberOfPlanes
        planeMovie = reshape(stack(:,:,planeIndex,:), ...
            numberOfRows, numberOfColumns, numberOfFrames);
        planeReference = [];
        if ~isempty(reference)
            planeReference = reference(:,:,planeIndex);
        end
        planeMovie = normcorre_batch(planeMovie, options, planeReference);
        stack(:,:,planeIndex,:) = reshape(planeMovie, ...
            numberOfRows, numberOfColumns, 1, numberOfFrames);
    end
else
    stack = normcorre_batch(stack, options, reference);
end
end%FCN:correctStack

%% ------------------------------------------------------------------------

function STACK = filterImages(STACK, SET)
% Filter each XY image independently in X-by-Y-by-Z-by-time trial arrays.
% sp: Gaussian sigma, median window width, or [median width, Gaussian sigma].
smoothingParameters = SET.SmoothData_spat;
filterType = SET.SmoothData_spat_type;

for trialIndex = 1:numel(SET.trial_names_clean)
    trialName = SET.trial_names_clean{trialIndex};
    trial = single(STACK.(trialName));
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
        end%switch
    end%iTrial


end%if fitler temporal
end%FCN:filterImages

%% ------------------------------------------------------------------------

function [STACK_seg, Segmentation] = segmentImages(STACK, SET)
% Segment XY planes in X-by-Y-by-Z-by-time trial arrays.
% together: segment concatenated trials once per plane, then share labels.
% template: segment trial 1 once per plane, then share labels.
% separate: segment each trial and plane independently.
% Summary statistics always describe the individual trial, before averaging.
% STACK is the input movie; region averaging is written only to STACK_seg.
% STACK_seg averages region pixels for BOTH methods, including background (ID 0).
% Background is averaged separately within each plane and trial.
% With segmentation disabled, STACK_seg equals STACK. Integer segmented data
% are converted to single to preserve fractional region means.
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

STACK_seg = STACK;
if segmentationEnabled
    for trialIndex = 1:numberOfTrials
        trialName = trialNames{trialIndex};
        if ~isfloat(STACK_seg.(trialName))
            STACK_seg.(trialName) = single(STACK_seg.(trialName));
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
            sourceMovies = cell(1, numel(sourceIndices));
            for sourceIndex = 1:numel(sourceIndices)
                sourceMovies{sourceIndex} = getPlane( ...
                    STACK.(trialNames{sourceIndices(sourceIndex)}), planeIndex);
            end
            sourceMovie = cat(3, sourceMovies{:});
            if strcmp(method, 'CalciSeg') && ~isfloat(sourceMovie)
                sourceMovie = single(sourceMovie);
            end
            if quiet
                evalc('[labelImage, sourceSummary] = feval(method, sourceMovie, segmentationArguments{:});');
            else
                [labelImage, sourceSummary] = ...
                    feval(method, sourceMovie, segmentationArguments{:});
            end
            clear sourceMovies sourceMovie
        else
            labelImage = reshape(1:size(firstTrial, 1)*size(firstTrial, 2), ...
                size(firstTrial, 1), size(firstTrial, 2));
            sourceSummary = struct([]);
        end

        for trialIndex = trialIndices
            trialName = trialNames{trialIndex};
            planeMovie = getPlane(STACK.(trialName), planeIndex);
            summary = sourceSummary;
            if segmentationEnabled && ~strcmp(mode, 'separate')
                summary = trialSummary(planeMovie, labelImage, sourceSummary);
            end
            Segmentation.(trialName)(planeIndex).pockets_labeled = labelImage;
            Segmentation.(trialName)(planeIndex).summary_stats = summary;

            if segmentationEnabled
                pixelTraces = reshape(planeMovie, [], size(planeMovie, 3));
                if ~isfloat(pixelTraces), pixelTraces = single(pixelTraces); end
                regionIDs = unique(labelImage(:)); % Include background (ID 0).
                for regionIndex = 1:numel(regionIDs)
                    regionPixels = labelImage(:) == regionIDs(regionIndex);
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
if displayLimit <= 0
    displayLimit = 1;
end
figureHandle = figure('Name', 'Manual ROI slicing', 'Color', 'w', ...
    'Units', 'normalized', 'Position', [0.05 0.05 0.9 0.85]);
figureCleanup = onCleanup(@() closeFigure(figureHandle)); %#ok<NASGU>
axesHandle = axes('Parent', figureHandle);

while true
    labelImage = zeros(imageSize);
    occupiedRaw = false(imageSize);
    cla(axesHandle);
    imagesc(axesHandle, displayImage, [0 displayLimit]);
    axis(axesHandle, 'image');
    axis(axesHandle, 'off');
    colormap(axesHandle, turbo);
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

function outputFolder = saveCRAPview(STACK, STACK_proc, Segmentation, SET, outputFolder, varargin)
%SAVECRAPVIEW Save one animal after dF/F calculation, before clearing arrays.
% saveCRAPview(STACK, STACK_proc, Segmentation, SET, outputFolder)
% Optional: 'SaveMoviesInMAT',false omits movies from results.mat. Both
% STACK and STACK_proc are ALWAYS exported to separate HDF5 files.
%
% STACK: fluorescence arrays, rows-by-columns-by-planes-by-time.
% STACK_proc: corresponding region-averaged dF/F arrays.
% Exports results.mat (-v7.3), stacks.h5, stacks_proc.h5, metadata.json, per-trial CSVs,
% and <trialName>.mp4, <trialName>_std_projection.pdf, and
% <trialName>_segmentation.pdf directly in outputFolder.
% STD projections and videos use SET.colmap; label PDFs use categorical colors.
% MP4 export requires MATLAB MPEG-4 support and a graphics-capable session.
% Baselines are reconstructed using the saved per-trial dFF_value and the
% current CRAPview baseline rule. Call BEFORE modifying these input arrays.
% Existing outputs require SET.overwrite=true and are retained in a backup.
% Failures leave the staging folder for inspection; COMPLETE.json identifies
% a completed export. PDF export requires export_fig on the MATLAB path.

parser = inputParser;
addParameter(parser,'SaveMoviesInMAT',true);
parse(parser,varargin{:});
saveMovies = parser.Results.SaveMoviesInMAT;
outputFolder = char(outputFolder);
[parentFolder,folderName] = fileparts(outputFolder);
assert(~isempty(folderName),'Specify an animal output folder, not a root directory.');
if isempty(parentFolder), parentFolder = pwd; end
outputFolder = fullfile(parentFolder,folderName);
overwrite = isfield(SET,'overwrite') && SET.overwrite;
assert(~isfile(outputFolder),'Output path is an existing file.');
if ~isfolder(outputFolder), mkdir(outputFolder); end
profiles = VideoWriter.getProfiles();
assert(any(strcmp({profiles.Name},'MPEG-4')), ...
    'This MATLAB installation does not support MPEG-4 video export.');
assert(exist('export_fig','file') ~= 0, 'Add export_fig to the MATLAB path.');
trialNames = SET.trial_names_clean;
videoNames = cellfun(@(name) [name '.mp4'],trialNames(:)', 'UniformOutput',false);
projectionNames = cellfun(@(name) [name '_std_projection.pdf'], ...
    trialNames(:)', 'UniformOutput',false);
segmentationNames = cellfun(@(name) [name '_segmentation.pdf'], ...
    trialNames(:)', 'UniformOutput',false);
exportNames = [{'COMPLETE.json','results.mat','stacks.h5','stacks_proc.h5','metadata.json'}, ...
    trialNames(:)', videoNames, projectionNames, segmentationNames];
existing = cellfun(@(name) isfile(fullfile(outputFolder,name)) || ...
    isfolder(fullfile(outputFolder,name)), exportNames);
assert(~any(existing) || overwrite, ...
    'Exports already exist. Set SET.overwrite=true to replace them.');
stagingFolder = [tempname(outputFolder), '_staging'];
mkdir(stagingFolder);
Traces = struct();
metadata.format_version = 1;
metadata.created_utc = char(datetime('now','TimeZone','UTC', ...
    'Format',"yyyy-MM-dd'T'HH:mm:ss'Z'"));
metadata.settings = jsonSafe(SET);
metadata.csv_matrix_orientation = 'rows=regions, columns=timepoints; no header';
metadata.labels_orientation = 'rows=image rows, columns=image columns; no header';
metadata.time_units = 'seconds';
metadata.dff_units = 'fraction, not percent';
metadata.fluorescence_units = 'same as input STACK (CRAPview uses scaled TIFF intensities)';
metadata.background = 'ID 0 included when present; averaged within each plane/trial';
metadata.hdf5_matlab_axes = {'row','column','plane','time'};
metadata.hdf5_raw_axes = {'time','plane','column','row'};
metadata.hdf5_python = 'h5py dataset[:].transpose(3,2,1,0) restores MATLAB axis order';
metadata.timestamp_note = 'Projection timestamps are mean retained-plane times; originals exported separately.';
metadata.baseline_note = 'Reconstructed from region fluorescence and per-trial dFF_value.';

% Export each trial and plane; trace-row mapping includes background ID 0.
for trialIndex = 1:numel(trialNames)
    trialName = trialNames{trialIndex};
    trialFolder = fullfile(stagingFolder,trialName);
    mkdir(trialFolder);
    trial = STACK.(trialName);
    processed = STACK_proc.(trialName);
    assert(isequal(size(trial),size(processed)), ...
        'STACK and STACK_proc sizes differ for %s.',trialName);
    numberOfFrames = size(trial,4);
    trialSettings = SET.(trialName);
    assert(isequal(size(trialSettings.relativeTime),[size(trial,3),numberOfFrames]) && ...
        isequal(size(trialSettings.absoluteTime),[size(trial,3),numberOfFrames]), ...
        'Timestamp dimensions do not match trial %s.',trialName);
    baselineValue = SET.dFF_value;
    if isfield(trialSettings,'dFF_value'), baselineValue = trialSettings.dFF_value; end

    for planeIndex = 1:size(trial,3)
        planeFolder = fullfile(trialFolder,sprintf('plane_%03d',planeIndex));
        mkdir(planeFolder);
        labels = Segmentation.(trialName)(planeIndex).pockets_labeled;
        assert(isequal(size(labels),[size(trial,1),size(trial,2)]) && ...
            all(isfinite(labels(:))) && all(labels(:) >= 0) && ...
            all(labels(:) == fix(labels(:))), 'Invalid label image for %s.',trialName);
        regionIDs = unique(labels(:));
        numberOfRegions = numel(regionIDs);
        pixelTraces = reshape(trial(:,:,planeIndex,:),[],numberOfFrames);
        processedTraces = reshape(processed(:,:,planeIndex,:),[],numberOfFrames);
        fluorescence = nan(numberOfRegions,numberOfFrames,'like',trial);
        dff = nan(numberOfRegions,numberOfFrames,'like',processed);
        pixelCounts = zeros(numberOfRegions,1);
        for regionIndex = 1:numberOfRegions
            pixels = labels(:) == regionIDs(regionIndex);
            fluorescence(regionIndex,:) = mean(pixelTraces(pixels,:),1,'omitnan');
            dff(regionIndex,:) = mean(processedTraces(pixels,:),1,'omitnan');
            pixelCounts(regionIndex) = nnz(pixels);
        end
        switch SET.dFF_type
            case 'window'
                assert(numel(baselineValue)==2 && all(isfinite(baselineValue)) && ...
                    all(baselineValue==fix(baselineValue)) && ...
                    baselineValue(1)>=1 && baselineValue(2)<=numberOfFrames && ...
                    baselineValue(1)<=baselineValue(2), 'Invalid saved baseline window.');
                baseline = mean(fluorescence(:,baselineValue(1):baselineValue(2)),2);
            case 'quantile'
                baseline = quantile(fluorescence,baselineValue,2);
            otherwise
                error('Unknown dFF_type: %s',SET.dFF_type);
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
        regions = table((1:numberOfRegions)',regionIDs,pixelCounts,roiNames,sliceIndices, ...
            'VariableNames',{'trace_row','region_id','pixel_count','roi_name','slice_index'});
        timing = table((1:numberOfFrames)',trialSettings.relativeTime(planeIndex,:)', ...
            trialSettings.absoluteTime(planeIndex,:)', ...
            'VariableNames',{'frame','relative_time_s','absolute_time_s'});
        baselineTable = table((1:numberOfRegions)',regionIDs,baseline, ...
            'VariableNames',{'trace_row','region_id','baseline_fluorescence'});
        writematrix(labels,fullfile(planeFolder,'labels.csv'));
        writetable(regions,fullfile(planeFolder,'regions.csv'));
        writematrix(fluorescence,fullfile(planeFolder,'fluorescence.csv'));
        writematrix(dff,fullfile(planeFolder,'dff.csv'));
        writetable(baselineTable,fullfile(planeFolder,'baseline.csv'));
        writetable(timing,fullfile(planeFolder,'imaging_times.csv'));
        Traces.(trialName)(planeIndex).regions = regions;
        Traces.(trialName)(planeIndex).fluorescence = fluorescence;
        Traces.(trialName)(planeIndex).dff = dff;
        Traces.(trialName)(planeIndex).baseline = baseline;
        Traces.(trialName)(planeIndex).baseline_value = baselineValue;
        Traces.(trialName)(planeIndex).imaging_times = timing;
    end

    % Create monatge
    metadata.pdfs.(trialName) = writeTrialPDFs(trial, ...
        Segmentation.(trialName), SET, stagingFolder, trialName);

    % Create mp4 video with fluorescence
    metadata.videos.(trialName) = writeTrialVideo(STACK.(trialName), ...
        trialSettings.relativeTime, fullfile(stagingFolder,[trialName '.mp4']),...
        SET, 'Fluorescence');

    % Create mp4 video with dff
    metadata.dff_videos.(trialName) = writeTrialVideo(STACK_proc.(trialName), ...
        trialSettings.relativeTime, fullfile(stagingFolder,[trialName '_dff.mp4']),...
        SET, '\Delta F/F_0');

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
writeStackHDF5(fullfile(stagingFolder,'stacks.h5'), STACK, 'STACK', ...
    'Exact supplied STACK fluorescence data.', metadata.fluorescence_units);
writeStackHDF5(fullfile(stagingFolder,'stacks_proc.h5'), STACK_proc, 'STACK_proc', ...
    'Exact supplied STACK_proc region-averaged dF/F data.', metadata.dff_units);
metadata.hdf5_stack_fields = fieldnames(STACK);
metadata.hdf5_stack_proc_fields = fieldnames(STACK_proc);
metadata.hdf5_stack_file = 'stacks.h5';
metadata.hdf5_stack_proc_file = 'stacks_proc.h5';
metadata.movies_in_mat = saveMovies;
writeJSON(fullfile(stagingFolder,'metadata.json'),metadata);
matFile = fullfile(stagingFolder,'results.mat');
if saveMovies
    save(matFile,'SET','Segmentation','Traces','STACK','STACK_proc','metadata','-v7.3');
else
    save(matFile,'SET','Segmentation','Traces','metadata','-v7.3');
end
writeJSON(fullfile(stagingFolder,'COMPLETE.json'), ...
    struct('complete',true,'created_utc',metadata.created_utc,'trial_count',numel(trialNames)));

% All temporary files and backups remain inside outputFolder.
backupFolder = '';
backedUp = {};
promoted = {};
try
    if any(existing)
        backupFolder = [tempname(outputFolder), '_previous'];
        mkdir(backupFolder);
        % Remove the previous completion marker before changing any data.
        for index = find(existing)
            name = exportNames{index};
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
rmdir(stagingFolder);
fprintf('Saved: %s\n',outputFolder);
if ~isempty(backupFolder), fprintf('Previous results retained: %s\n',backupFolder); end
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

function videoInfo = writeTrialVideo(movie, relativeTime, filename, SET, color_label)
% Display STACK fluorescence with a separate fixed color scale for each plane.
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
    if isempty(samples)
        limits(planeIndex,:) = [0 1];
    else
        limits(planeIndex,:) = double(quantile(samples(:),[0.01 0.99]));
        if limits(planeIndex,1) == limits(planeIndex,2)
            padding = max(1,abs(limits(planeIndex,1))) * 0.01;
            limits(planeIndex,:) = limits(planeIndex,:) + [-padding padding];
        end
    end
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
    title(axesHandle,sprintf('Plane %d',planeIndex));
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
videoInfo.source = 'STACK';
videoInfo.units = 'same fluorescence units as input STACK';
videoInfo.color_limits = limits; % One row [lower upper] per plane.
videoInfo.color_limits_method = 'Per-plane sampled 1st/99th percentiles, fixed across all frames.';
videoInfo.frame_rate_hz = frameRate;
videoInfo.frame_count = numberOfFrames;
videoInfo.timing = 'Constant-rate playback using median volume interval; title shows recorded time.';
end

function deleteVideoFigure(figureHandle)
if isgraphics(figureHandle), delete(figureHandle); end
end
function pdfInfo = writeTrialPDFs(trial, planeSegmentation, SET, folder, trialName)
% One panel per plane, using the exact STACK data and saved segmentation.
numberOfPlanes = size(trial,3);
numberOfColumns = ceil(sqrt(numberOfPlanes));
numberOfRows = ceil(numberOfPlanes / numberOfColumns);
projectionName = [trialName '_std_projection.pdf'];
segmentationName = [trialName '_segmentation.pdf'];

% Temporal standard deviation; imagesc automatically scales each plane.
projection = std(trial,0,4,'omitnan');
projectionLimits = zeros(numberOfPlanes,2);
figureHandle = figure('Color','w','Visible','off','Units','pixels', ...
    'Position',[100 100 1200 800]);
figureCleanup = onCleanup(@() deleteVideoFigure(figureHandle));
layout = tiledlayout(figureHandle,numberOfRows,numberOfColumns, ...
    'TileSpacing','compact','Padding','compact');
for planeIndex = 1:numberOfPlanes
    axesHandle = nexttile(layout);
    planeProjection = projection(:,:,planeIndex);
    imageHandle = imagesc(axesHandle,planeProjection);
    projectionLimits(planeIndex,:) = get(axesHandle,'CLim');
    set(imageHandle,'AlphaData',isfinite(planeProjection));
    axis(axesHandle,'image');
    axis(axesHandle,'off');
    title(axesHandle,sprintf('Plane %d',planeIndex));
    colorbarHandle = colorbar(axesHandle);
    colorbarHandle.Label.String = 'Temporal fluorescence STD';
end
colormap(figureHandle,SET.colmap);
title(layout,[trialName ' | temporal STD'],'Interpreter','none');
drawnow;
export_fig(figureHandle,fullfile(folder,projectionName),'-pdf','-painters');
clear figureCleanup

% Assign deterministic categorical colors; label 0 is black. The same
% numeric label has the same color in every plane of this trial.
regionIDs = [];
for planeIndex = 1:numberOfPlanes
    labels = planeSegmentation(planeIndex).pockets_labeled;
    regionIDs = union(regionIDs,unique(labels(labels > 0)));
end
numberOfRegions = numel(regionIDs);
hues = mod((0:numberOfRegions-1)' * 0.618033988749895,1);
regionColors = hsv2rgb([hues,0.65*ones(numberOfRegions,1),0.95*ones(numberOfRegions,1)]);
palette = [0 0 0; regionColors];
figureHandle = figure('Color','w','Visible','off','Units','pixels', ...
    'Position',[100 100 1200 800]);
figureCleanup = onCleanup(@() deleteVideoFigure(figureHandle)); %#ok<NASGU>
layout = tiledlayout(figureHandle,numberOfRows,numberOfColumns, ...
    'TileSpacing','compact','Padding','compact');
for planeIndex = 1:numberOfPlanes
    axesHandle = nexttile(layout);
    labels = planeSegmentation(planeIndex).pockets_labeled;
    [~,colorIndices] = ismember(labels,regionIDs);
    rgbImage = reshape(palette(colorIndices(:)+1,:),[size(labels),3]);
    image(axesHandle,rgbImage);
    axis(axesHandle,'image');
    axis(axesHandle,'off');
    title(axesHandle,sprintf('Plane %d',planeIndex));
    % Print IDs for manageable segment counts; CSVs always retain all IDs.
    planeIDs = unique(labels(labels > 0));
    if numel(planeIDs) <= 100
        for regionIndex = 1:numel(planeIDs)
            [rows,columns] = find(labels == planeIDs(regionIndex));
            text(axesHandle,mean(columns),mean(rows),num2str(planeIDs(regionIndex)), ...
                'HorizontalAlignment','center','Color','k','FontSize',8);
        end
    end
end
title(layout,[trialName ' | segmentation (background = black)'],'Interpreter','none');
drawnow;
export_fig(figureHandle,fullfile(folder,segmentationName),'-pdf','-painters');

pdfInfo.std_projection = projectionName;
pdfInfo.segmentation = segmentationName;
pdfInfo.std_source = 'STACK; sample standard deviation over dimension 4, omitting NaNs';
pdfInfo.std_color_limits = projectionLimits; % Record automatic limits only.
pdfInfo.std_color_limits_method = 'Automatic imagesc scaling, independently per plane.';
pdfInfo.std_colormap = jsonSafe(SET.colmap);
pdfInfo.label_colors = 'Categorical HSV colors in golden-ratio hue order; background black';
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

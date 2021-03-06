
%% Establish IEEG Sessions
% Establish IEEG Sessions through the IEEGPortal. This will allow on demand
% data access

%add folders to path
addpath(genpath('../../../../Libraries/ieeg-matlab-1.13.2'));
addpath(genpath('../portalGit/Analysis'))
addpath(genpath('../portalGit/Utilities'))

%Load data
params = initialize_task_spike;
% Load data
session = loadData(params);
 
% % Get training set
class1_layers = {'PFC','I','C'};
class2_layers = {'Noise'};

%% RUN SPIKE JA

%set channels
channelIdxs = cell(numel(session.data),1);
for i = 1:numel(session.data)
    channelIdxs{i} = 1:numel(session.data(i).rawChannels);
end

for i = 1:numel(session.data)
    [spikeTimes, spikeChannels,DE] = spike_ja_wrapper(session.data(i),channelIdxs{i});
    uploadAnnotations(session.data(i),'spike_ja',spikeTimes,spikeChannels,'spike','overwrite');
end

%find those in original true and false layers, find nearest spike_ja spike,
%and reassign to "true spike", "false spike"
for i = 1:numel(session.data)
    leftWin = 0.1;
    rightWin = 0.1;
    
    % CLASS 1
    allTimes = [];
    allChannels = [];
    for j = 1:numel(class1_layers)
       [~,timesUSec,channels] = getAnnotations(session.data(i),class1_layers{j});
       allTimes = [allTimes; timesUSec];
       allChannels = [allChannels ; channels];
    end
    [~,cand_times, cand_channels] = getAnnotations(session.data(i),'spike_ja');

    idx = zeros(size(cand_times,1),1);
    for k = 1:size(cand_times,1)
        tmp = find((cand_times(k,1)-leftWin*1e6)<allTimes(:,1) & (cand_times(k,2)+rightWin*1e6)>allTimes(:,2));
        if ~isempty(tmp)
            idx(k) = 1;
        end
    end
    idx = logical(idx);
    c1_spikes = cand_times(idx);
    c1_chan = cand_channels(idx); 
    uploadAnnotations(session.data(i),'true_spikes',c1_spikes,c1_chan,'spike','append')

    % CLASS 2
    allTimes = [];
    allChannels = [];
    for j = 1:numel(class2_layers)
       [~,timesUSec,channels] = getAnnotations(session.data(i),class2_layers{j});
       allTimes = [allTimes; timesUSec];
       allChannels = [allChannels ; channels];
    end
    [~,cand_times, cand_channels] = getAnnotations(session.data(i),'spike_ja');

    idx = zeros(size(cand_times,1),1);
    for k = 1:size(cand_times,1)
        tmp = find((cand_times(k,1)-leftWin*1e6)<allTimes(:,1) & (cand_times(k,2)+rightWin*1e6)>allTimes(:,2));
        if ~isempty(tmp)
            idx(k) = 1;
        end
    end
    idx = logical(idx);
    c2_spikes = cand_times(idx);
    c2_chan = cand_channels(idx); 
    uploadAnnotations(session.data(i),'false_spikes',c2_spikes,c2_chan,'noise','append')
end

%% pull true and false spikes, train detector, detect rest of candidate spikes
for i = 1:numel(session.data)
    feat = runFuncOnAnnotations(session.data(i),@features_comprehensive,'layerName','false_spikes','useAllChannels',0,'feature_params',{'cwt'},'PadStartBefore',0.05,'PadEndAfter',0.2);
    feat2 = runFuncOnAnnotations(session.data(i),@features_comprehensive,'layerName','true_spikes','useAllChannels',0,'feature_params',{'cwt'},'PadStartBefore',0.05,'PadEndAfter',0.2);
    %run on origin markings
    feat3 = runFuncOnAnnotations(session.data(i),@features_comprehensive,'layerName','spike_ja','useAllChannels',0,'feature_params',{'cwt'},'PadStartBefore',0.05,'PadEndAfter',0.2);

    trainset = [cell2mat(feat);cell2mat(feat2)];
    colmeans = mean(trainset);
    labels = [zeros(numel(feat),1);ones(numel(feat2),1)];
    [evectors, score, evalues] = pca(trainset);
    trainset = score;
    
    testset = cell2mat(feat3);
    testset= testset-repmat(colmeans,size(feat3,1),1);
    testset = testset*evectors;

	mod = TreeBagger(500,trainset,labels,'method','Classification','OOBPredictorImportance','on','Cost',[0 20; 1 0]);
	save('RFmod.mat','mod');
    oobErrorBaggedEnsemble = oobError(mod);
    plot(oobErrorBaggedEnsemble)
    xlabel 'Number of grown trees';
    ylabel 'Out-of-bag classification error';


    [yhat,scores] = oobPredict(mod);
    [conf, classorder] = confusionmat(categorical(labels), categorical(yhat))

    imp = mod.OOBPermutedPredictorDeltaError;
    predictorNames = {};
    for pc = 1:max(30,size(trainset,2))
        predictorNames{pc} = sprintf('%d',pc');
    end
    figure;
    bar(imp);
    ylabel('Predictor importance estimates');
    xlabel('PC');
    h = gca;
    h.XTick = 1:2:60
    h.XTickLabel = predictorNames
    h.XTickLabelRotation = 45;
    h.TickLabelInterpreter = 'none';

%   plot imp back to original wavelet space
%   pcs = 1:60;
%   waveCoeff = imp(pcs)*evectors(:,pcs)';
%   rwave = reshape(waveCoeff,60,[]);
%   imagesc(rwave);
%   colorbar;
%   xlim([50, 400])
%   xlabel('Sample')
%   ylabel('Scale')
%   set(gca,'FontSize',14);
%   set(gca,'YDir','normal');
    
    [yhat ypred] = predict(mod,testset);
    [~,detected_times,detected_channels] = getAnnotations(session.data(i),'spike_ja');
    [a, class] = max(ypred,[],2);
    uploadAnnotations(session.data(i),'detected_spike',detected_times(class==2),detected_channels(class==2),'spike','overwrite');
end



allThreshold = cell(numel(session.data),1);
winLen = zeros(numel(session.data),1);
durations = cell(numel(session.data),1);
recommended_multiplier =  cell(numel(session.data),1);
for i = 1:numel(session.data)
    [sugg_abs_thres, sugg_rel_thres, sugg_mult, sugg_win_len] = getHypersensitiveParams(session.data(i),train_layers{1},'pad_mult',2,'background_thres_mult', ...
        3.5,'show_plots',0,'detect_spikes',1);
    allThreshold{i} = sugg_abs_thres;
    winLen(i) = sugg_win_len;
    recommended_multiplier{i} = sugg_mult;
    %catch
    %end
end


% params.timeOfInterest=[];%[0 60*60*24];
% params.filtFlag = 0;
% params.blockLen = 15*60*1; 
% for i =1
%     params.winLen = winLen(i);
%     params.winDisp = winLen(i);
%     spike_detecotr_general(session.data(i),channelIdxs{i},',{'LL'});
% end



%%
allDat = getAllData(session.data(i),3,3600);
fs = session.data(i).sampleRate;
LLFn2 = @(X, winLen) conv2(abs(diff(X,1)),  repmat(1/winLen,winLen,1),'same');
LLFn = @(x) (abs(diff(x)));
feats = LLFn2(allDat,winLen(i)*fs);
feats2 = LLFn(allDat);

[pks loc] = findpeaks(feats,'MinPeakHeight',allThreshold{i}(:,3));
loc(loc<(2*fs)) = []; %remove spikes in first 2 seconds due to noise
ch = cell(numel(loc),1);
for chi = 1:numel(loc)
    ch{chi} = 3;
end


% go through detections and identify ones that are artifacts/false
% detections through false layer
for i = 1:numel(class2_layers)
    [~,times,chan] = getAnnotations(session.data(1),class2_layers{i});
    new_times = times(:,1)/1e6*fs;
    for j = 1:numel(new_times)
        new_times(j)
    end
end
eventMarking(session.data(i),[(loc/fs-0.05)*1e6 (loc/fs+0.2)*1e6],ch,'numToVet',30,'intelligent',0,'feature_params', ...
   {'cwt'})
eventMarking(session.data(i),[(loc/fs-0.05)*1e6 (loc/fs+0.2)*1e6],ch,'numToVet',30,'intelligent',1,'feature_params', ...
   {'cwt'})

%idx = cellfun(@(x)numel(x)>1,eventChannels);
%layerName = 'burst-candidate';
%eventMarking(session.data(i),eventTimesUSec(idx,:),eventChannels(idx),layerName)

%add marked bursts to correct layer
%[~, times, channels] = getAnnotations(session.data(i),train_layers{1});
%uploadAnnotations(session.data(i),'Type B',times,channels,'Type B','append')


%load true and false layers (Type A, Type B, get features, train, and
%classify rest)
%[~, falseTimes, falseChannels] = getAnnotations(session.data(i),'Type A');
%[~, trueTimes, trueChannels] = getAnnotations(session.data(i),'Type B');

runOnWin = 0;
feat = runFuncOnAnnotations(session.data(i),'true_spikes',@features_comprehensive,'runOnWin',0,'useAllChannels',0);
%
feat2 = runFuncOnAnnotations(session.data(i),'false_spikes',@features_comprehensive,'runOnWin',0,'useAllChannels',0);

%run on origin markings
feat3 = runFuncOnAnnotations(session.data(i),'spike_ja',@features_comprehensive,'runOnWin',0,'useAllChannels',0);

trainset = [cell2mat(feat);cell2mat(feat2)];
labels = [zeros(numel(feat),1);ones(numel(feat2),1)];

load('RFmod.mat');
% 
% mod = TreeBagger(300,trainset,labels,'method','Classification','OOBPredictorImportance','on','Cost',[0 1; 2 0]);
% save('RFmod.mat','mod');
% oobErrorBaggedEnsemble = oobError(mod);
% plot(oobErrorBaggedEnsemble)
% xlabel 'Number of grown trees';
% ylabel 'Out-of-bag classification error';
% 
% 
% [yhat,scores] = oobPredict(mod);
% [conf, classorder] = confusionmat(categorical(labels), categorical(yhat))
% disp(dataset({conf,classorder{:}}, 'obsnames', classorder));
% 
% imp = mod.OOBPermutedPredictorDeltaError;
% predictorNames = {};
% for i = 1:60
%     predictorNames{i} = sprintf('%d',i');
% end
% figure;
% bar(imp);
% ylabel('Predictor importance estimates');
% xlabel('PC');
% h = gca;
% h.XTick = 1:2:60
% h.XTickLabel = predictorNames
% h.XTickLabelRotation = 45;
% h.TickLabelInterpreter = 'none';

load(sprintf('%s-burstspatial.mat',session.data(i).snapName));
test.eventChannels = eventChannels;
test.eventTimesUSec = eventTimesUSec;
[yhat yhat_scores] = testModelOnAnnotations_par(session.data(i),'Type B',mod,@features_comprehensive,'runOnWin',0,'useAllChannels',1,'customTimeWindows',test);


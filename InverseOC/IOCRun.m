function IOCRun(trialInfo, savePath)
    frameDelim = '_';

    if ~exist('savePath', 'var')
        savePath = '';
    end
    
    % Return to calling function if no trial info is passed along
    if isempty(fieldnames(trialInfo))
        disp('No trial info was given');
        return
    end
    
    % Load to memory model and information needed for running IOC
    if 0 % wanxin modification trial
        model = ArmModelRL();
        model.loadModelOnly();
        [q, dq, ddq, tau, states, control, trajT, trajU, trajX, model] = modifyModelWX(model);
    else
%         model = ArmModelRL();
%         model.loadAndSetupIIT(trialInfo.path, trialInfo);
%         model.initModel();  
        model = getModel(trialInfo);
        [q, dq, ddq, tau, states, control, trajT, trajU, trajX, frameInds] = loadData(trialInfo, model);
    end
    
    trialInfo.frameInds = frameInds;
    trialInfo.numWeights = length(trialInfo.candidateFeatures);
    trialInfo.numDofs = model.totalActuatedJoints;
    

    % generate default trialInfo if missing
    % weights
    if isempty(trialInfo.weights)
        trialInfo.weights = ones(1, trialInfo.numWeights);
    end
    
    % gamma
    if isempty(trialInfo.gamma)
        trialInfo.gamma = trialInfo.numWeights+trialInfo.numDofs-1;
    end
    
    trialInfo.trueWeights = (trialInfo.weights)'/sum(trialInfo.weights);

    % Initialization
    % trialInfo, model, data loaded
    % (Paper Sec. II: Problem formulation, eqs. (1)–(3))
    % Initialization of threshold and condition variables
    dt = trajT(2) - trajT(1);

    % Create IOC instance
    ioc = IOCInstanceNew(model, dt);
    ioc.init(trialInfo);
%     ioc.setFeatureNormalization(trajX, trajU);
    
    switch trialInfo.displayInfo
        case {'verbose', 'final'}
            fprintf('Pre-calculating the features/dynamics... \n');
    end
        
    precalcAllFrames = [frameInds frameInds(end)+(1:trialInfo.maxWinLen)];
    
    if max(precalcAllFrames) > size(trajX, 1)
        precalcAllFrames = precalcAllFrames(1):size(trajX, 1);
    end
    
    trialInfo.lenDof = size(trajX, 2)/2;
    trialInfo.hWant = (size(trajX, 2) + trialInfo.numWeights) * trialInfo.dimWeights;

    % Precompute features & dynamics (Paper Sec. II, union feature φ(x,u))
    iocFeatures = ioc.calcFeatures(trajX(precalcAllFrames, :), trajU(precalcAllFrames, :));
    iocDynamics = ioc.calcDynamics(trajX(precalcAllFrames, :), trajU(precalcAllFrames, :));
 
    if trialInfo.saveIntermediate > 0 
        saveInds = [];
        for i = 1:ceil(frameInds(end)/trialInfo.saveIntermediate)
            saveInds = [saveInds; (i-1)*trialInfo.saveIntermediate i*trialInfo.saveIntermediate-1];
        end
        
        saveInds(1, 1) = 1;
        saveInds(end, 2) = frameInds(end);
    else
        saveInds(1, 1) = 1;
        saveInds(1, 2) = frameInds(end);
    end

    % Precompute gradients for recovery matrix construction
    % (Paper eqs. (11)–(12): H1, H2 depend on ∂f/∂x, ∂f/∂u, ∂φ/∂x, ∂φ/∂u)
    % precalc singular H1 and H2 matrix
    precalcGradient = precalculateGradient_initialize(trajX, trajU, ioc, 1:trialInfo.maxWinLen, trialInfo);
    
    progressVar = [];
    progressVar(frameInds(end)).weights = [];
    progressVar(frameInds(end)).winInds = [];
    progressVar(frameInds(end)).rankTraj = [];
    progressVar(frameInds(end)).rankPass = [];
    progressVar(frameInds(end)).error = [];
    
    processSecondaryVar = [];
    processSecondaryVar(frameInds(end)).H1 = [];
    processSecondaryVar(frameInds(end)).H2 = [];
    processSecondaryVar(frameInds(end)).H = [];

    % Loop over trajectory frames (Paper Sec. IV: Sliding window over trajectory)
    % assemble and assess H
    for indFrame = frameInds
        % Incrementally build recovery matrix H(t,l)
        % (Paper eq. (10): H = [H1 H2], updated via eq. (14))
        [progressVar(indFrame), processSecondaryVar(indFrame), precalcGradient] = calcWinLenAndH(trajT, trajX, trajU, dt, ioc, indFrame - 1, precalcGradient, trialInfo);
        
        % save either on the regular intervals, or at the last frame
        checkSave = find(indFrame == saveInds(:, 2));
        
        if (~isempty(checkSave))    
            currSaveInds = saveInds(checkSave, :);
            currSaveRange = currSaveInds(1):currSaveInds(end);
            
            outputVar_data.frameInds = currSaveInds;
            outputVar_data.t = trajT(currSaveRange);
            outputVar_data.q = q(currSaveRange, :);
            outputVar_data.dq = dq(currSaveRange, :);
            outputVar_data.tau = tau(currSaveRange, :);
            outputVar_data.dt = dt;
            
            outputVar_data.lenDof = trialInfo.lenDof;
            outputVar_data.lenState = size(trajX, 2);
            outputVar_data.lenControl = size(trajU, 2);
            
            outputVar_data.featureLabels = ioc.getFeatureListAsString();
            outputVar_data.features = iocFeatures(currSaveRange, :);
            outputVar_data.dynamics = iocDynamics(currSaveRange, :);
                        
            outputVar_weights.trialInfo = trialInfo;
            outputVar_weights.timeElapsed = toc;
            outputVar_weights.timeElasedPerFrame = toc/length(frameInds);
            
            outputVar_weights.frameInds = currSaveInds;
            outputVar_weights.progress = progressVar(currSaveRange);
            
            outputVar_weights.minLenThres = trialInfo.hWant / outputVar_data.lenDof;
            outputVar_weights.maxLenThres = trialInfo.maxWinLen;
            outputVar_weights.minRankThres = trialInfo.gamma;
            
            % outputVar.errorTraj = errorTraj;
            % outputVar.rankTraj = rankTraj;
            % outputVar.weightTraj = weightTraj;
            % outputVar.completeTraj = completeTraj;
            % outputVar.rankPassCodeTraj = rankPassCodeTraj;
            
            % outputVar.segmentArray = segmentArray; % remove the first initialized value
            outputVar_supp.frameInds = currSaveInds;
            outputVar_supp.processSecondaryVar = processSecondaryVar(currSaveRange);
            
            numSuffix = [num2str(currSaveInds(1), '%06.f') '_' num2str(currSaveInds(2), '%06.f')];

            finalPath_data = fullfile(savePath, ['data' frameDelim numSuffix '.mat']);
            finalPath_weights = fullfile(savePath, ['weights' frameDelim numSuffix '.mat']);
            finalPath_supp = fullfile(savePath, ['supp' frameDelim numSuffix '.mat']); 
            
            save(finalPath_data, 'outputVar_data');
            save(finalPath_weights, 'outputVar_weights');
            save(finalPath_supp, 'outputVar_supp');
            
            progressVar = [];
            progressVar(frameInds(end)).weights = [];
            progressVar(frameInds(end)).winInds = [];
            progressVar(frameInds(end)).rankTraj = [];
            progressVar(frameInds(end)).rankPass = [];
            progressVar(frameInds(end)).error = [];
            
            processSecondaryVar = [];
            processSecondaryVar(frameInds(end)).H1 = [];
            processSecondaryVar(frameInds(end)).H2 = [];
            processSecondaryVar(frameInds(end)).H = [];
        end
    end
end

function [q, dq, ddq, tau, states, control, trajT, trajU, trajX, model] = modifyModelWX(model)
    load('D:\aslab\projects\jf2lin\TROcopy\sub5.mat');
%     bodyPara = Para;

    bodyPara.lankle = 0.3700;
    bodyPara.lknee = 0.4000;
    bodyPara.lhip = 0.4500;
    bodyPara.mass = 65.7000;

    %legnth settings;
    l1=bodyPara.lankle;
    l2=bodyPara.lknee;
    l3=bodyPara.lhip;
    %mass settings
    m1=0.045*bodyPara.mass;      %0.09
    m2=0.146*bodyPara.mass;       %0.29
    m3=0.2985*bodyPara.mass;      %0.62
    %CoM position settings
    r1=(0.404)*l1;
    r2=(0.377)*l2;
    r3=(0.436)*l3;
    %moments of inertia settings
    I1=(0.28*l1)^2*m1;
    I2=(0.32*l2)^2*m2;             %0.35
    I3=(0.29*l3)^2*m3;             %0.30
    
    kinematicTransform(1).frameName = 'length_rknee_rankle';
    dynamicTransform(1).frameName = 'body_rknee_rankle';
    kinematicTransform(2).frameName = 'length_rhip_rknee';
    dynamicTransform(2).frameName = 'body_rhip_rknee';
    kinematicTransform(3).frameName = 'length_torso_rhip';
    dynamicTransform(3).frameName = 'body_torso_rhip';
    
%     kinematicTransform(4).frameName = 'length_rankle_rballfoot';
    
    kinematicTransform(1).t = eye(4);
    kinematicTransform(2).t = eye(4);
    kinematicTransform(3).t = eye(4);
%     kinematicTransform(4).t = eye(4);
    
    % determine which joint parameters use for defining upper-arm length
    % and second link inertia information
            kinematicTransform(1).t(2, 4) = l1; % apply link length to the upper arm
            kinematicTransform(2).t(2, 4) = l2;
            kinematicTransform(3).t(2, 4) = l3;
%             
            dynamicTransform(1).m = m1;
            dynamicTransform(1).com = [0 r1 0]';
            dynamicTransform(1).I(1, 1) = I1;
            dynamicTransform(1).I(2, 2) = I1;
            dynamicTransform(1).I(3, 3) = 0;
            
            dynamicTransform(2).m = m2;
            dynamicTransform(2).com = [0 r2 0]';
            dynamicTransform(2).I(1, 1) = I2;
            dynamicTransform(2).I(2, 2) = I2;
            dynamicTransform(2).I(3, 3) = 0;
            
            dynamicTransform(3).m = m3;
            dynamicTransform(3).com = [0 r3 0]';
            dynamicTransform(3).I(1, 1) = I3;
            dynamicTransform(3).I(2, 2) = I3;
            dynamicTransform(3).I(3, 3) = 0;
        
    
    model.addKinDynTransformToModel(kinematicTransform, dynamicTransform);
    
    qOrig = q;
    dqOrig = dq;
    ddqOrig = ddq;
    
    q = [qOrig.ankle, qOrig.knee, qOrig.hip];
    dq = [dqOrig.ankle, dqOrig.knee, dqOrig.hip];
    ddq = [ddqOrig.ankle, ddqOrig.knee, ddqOrig.hip];
    
    tau = zeros(size(q));
    for indTime = 1:length(time.time) % recalc torque given redistributed masses
        %                 model.updateState(q(indTime, :), dq(indTime, :));
        tau(indTime, :) = model.inverseDynamicsQDqDdq(q(indTime, :), dq(indTime, :), ddq(indTime, :));
    end
    
    trajT = time.time';
    trajX = encodeState(q, dq);
    trajU = tau;
    
    states = trajX;
    control = trajU;
end

function [q, dq, ddq, tau, states, control, trajT, trajU, trajX, frameInds] = loadData(trialInfo, model)
    % Load state, control and time trajectories to be analyzed.
    switch trialInfo.baseModel
        case {'IIT','Jumping'}
            switch trialInfo.model
                case 'Jumping2D'
                    load(trialInfo.path);
                    
                    targNum = trialInfo.targNum;
                    jumpNum = trialInfo.jumpNum;
                            
                    param.jump.takeoffFrame = JA.TOFrame(jumpNum,targNum);
                    param.jump.landFrame = JA.LandFrame(jumpNum,targNum);
                    param.jump.locationLand = JA.locationLand(12*(targNum-1) + jumpNum);
                    param.jump.grade = JA.jumpGrades(12*(targNum-1) + jumpNum);
                    param.jump.modelLinks = JA.modelLinks;
                    param.jump.world2base = squeeze(JA.world2base((12*(targNum-1) + jumpNum),:,:));
                    param.jump.bad2d = JA.bad2D(jumpNum,targNum);
                    
                    % Crop out initial and final calibration motions
%                     takeoffFrames = 200; % 1 second before takeoff frame ...
%                     landFrames = 300; % ... to 1.5 seconds after takeoff frame (~ 1 second after landing)
%                     framesToUse = (param.jump.takeoffFrame-takeoffFrames):(param.jump.takeoffFrame+landFrames);
                    
                    takeoffFrames = 0; % 1 second before takeoff frame ...
                    landFrames = 0; % ... to 1.5 seconds after takeoff frame (~ 1 second after landing)
                    framesToUse = (param.jump.takeoffFrame-takeoffFrames):(param.jump.landFrame+landFrames);
                    
                    if(numel(framesToUse) < size(JA.targ(targNum).jump(jumpNum).data,1))
                        fullDataAngles = JA.targ(targNum).jump(jumpNum).data(framesToUse,:);
                    else % jump recording stops sooner than "landFrames" after TOFrame
                        fullDataAngles = JA.targ(targNum).jump(jumpNum).data( framesToUse(1):end ,:);
                        fullDataAngles = [fullDataAngles; repmat(fullDataAngles(end,:),(numel(framesToUse) - size(fullDataAngles,1)),1)]; % repeat last joint angle measurement for remainder of frames
                    end
                    
                    % keep only a subset of the joint angles
                    qInds = [];
                    allJointStr = {model.model.joints.name}';
                    for indQ = 1:length(allJointStr)
                        qInds(indQ) = find(ismember(model.modelJointNameRemap, allJointStr{indQ}));
                    end
                    
                    % also, negate the following joints since they're past
                    % the flip
                    qFlip = fullDataAngles;
%                     jointsToFlip = {'rankle_jDorsiflexion', 'rknee_jExtension', 'rhip_jFlexion'};
% %                     jointsToFlip = {'rankle_jDorsiflexion', 'rknee_jExtension', 'rhip_jFlexion', 'back_jFB', 'rjoint1'};
%                     for indQ = 1:length(jointsToFlip)
%                         qIndsFlip(indQ) = find(ismember(model.modelJointNameRemap, jointsToFlip{indQ}));
%                         qFlip(:, qIndsFlip(indQ)) = -fullDataAngles(:, qIndsFlip(indQ));
%                     end
                    
                    dt = 0.005;
                    time = dt*(0:(size(qFlip, 1)-1));
                    qRaw = qFlip(:, qInds);
                    q = filter_dualpassBW(qRaw, 0.04, 0, 5);
                    
                    dqRaw = calcDerivVert(q, dt);
                    dq = filter_dualpassBW(dqRaw, 0.04, 0, 5);
                    %             dq = dqRaw;
                    
                    % don't filter ddq and tau to keep
                    ddqRaw = calcDerivVert(dq, dt);
                    %             ddq = filter_dualpassBW(ddqRaw, 0.04, 0, 5);
                    ddq = ddqRaw;
                    
                    tauRaw = zeros(size(q));
                    for indTime = 1:length(time) % recalc torque given redistributed masses
                        %                 model.updateState(q(indTime, :), dq(indTime, :));
                        tauRaw(indTime, :) = model.inverseDynamicsQDqDdq(q(indTime, :), dq(indTime, :), ddq(indTime, :));
                    end
                    
                    %             tau = filter_dualpassBW(tauRaw, 0.04, 0, 5);
                    tau = tauRaw;
                    
                    %             states = [q dq];
                    states = encodeState(q, dq);
                    control = tau;
                    
                    trajT = time';
                    trajU = control;
                    trajX = states;
                    
                otherwise
                    load(trialInfo.path);
                    
                    % keep only the joint angles corresponding
                    qInds = [];
                    allJointStr = {model.model.joints.name}';
                    
                    for indQ = 1:length(allJointStr)
                        qInds(indQ) = find(ismember(saveVar.jointLabels, allJointStr{indQ}));
                    end
                    
                    time = saveVar.time;
                    qRaw = saveVar.jointAngle.array(:, qInds);
                    q = filter_dualpassBW(qRaw, 0.04, 0, 5);
                    
                    dqRaw = calcDerivVert(q, saveVar.dt);
                    dq = filter_dualpassBW(dqRaw, 0.04, 0, 5);
                    %             dq = dqRaw;
                    
                    % don't filter ddq and tau to keep
                    ddqRaw = calcDerivVert(dq, saveVar.dt);
                    %             ddq = filter_dualpassBW(ddqRaw, 0.04, 0, 5);
                    ddq = ddqRaw;
                    
                    tauRaw = zeros(size(q));
                    for indTime = 1:length(time) % recalc torque given redistributed masses
                        %                 model.updateState(q(indTime, :), dq(indTime, :));
                        tauRaw(indTime, :) = model.inverseDynamicsQDqDdq(q(indTime, :), dq(indTime, :), ddq(indTime, :));
                    end
                    
                    %             tau = filter_dualpassBW(tauRaw, 0.04, 0, 5);
                    tau = tauRaw;
                    
                    %             states = [q dq];
                    states = encodeState(q, dq);
                    control = tau;
                    
                    trajT = time';
                    trajU = control;
                    trajX = states;
            end
            
         otherwise
             inputPath = char(trialInfo.path);
             %inputPath = char(sprintf('%s%s', trialInfo.path, trialInfo.name));
             
            data = cell2mat(struct2cell(load(inputPath)));
            time = data(:,1);
            tau = data(:,2:numDofs+1);
            statesRaw = data(:, numDofs+2:end);
            
            q = statesRaw(:, 1:numDofs);
            dq = statesRaw(:, (numDofs+1):end);
            states = encodeState(q, dq);
            control = tau;
             
            % Approximate trajectories using splines
            trajT = linspace(0,1,1001);
            trajU = interp1(time, control, trajT,'spline');
            trajX = interp1(time, states, trajT,'spline');
    end    
    
    if ~isempty(trialInfo.runInds)
        frameInds = trialInfo.runInds(1):trialInfo.runInds(2);
    else
        frameInds = 1:length(trajT);
    end
    
    if max(frameInds) > length(trajT)
        frameInds = frameInds(1):length(trajT);
    end
    
    if 0
        mdl = model.model;
        vis = rlVisualizer('vis',640,480);
        mdl.forwardPosition();
        vis.addModel(mdl);
        vis.addMarker('x-axis', [1 0 0], [0.2 0.2 0.2 1]);
        vis.addMarker('y-axis', [0 1 0], [0.2 0.2 0.2 1]);
        vis.addMarker('z-axis', [0 0 1], [0.2 0.2 0.2 1]);
        vis.update();
        
%         mdl.base = 'world'; % ok
%         mdl.base = 'pframe0'; % ok
%         mdl.base = 'rframe0'; % ok
%         mdl.base = 'mid_asis';
%         mdl.base = 'rhip0';
%         mdl.base = 'rtoe0';
        
%         q(:, 1:3) = zeros(size(q(:, 1:3)));
%         qFull = filter_dualpassBW(fullDataAngles, 0.04, 0, 5);
%         qFull(:, 1) = qFull(:, 1) + 0.4;
%         mdl_old = model.model_old;
%         vis.addModel(mdl_old);
        
        for i = 1:length(trajT)
            mdl.position = q(i, :);
            mdl.forwardPosition();
            
%             mdl_old.position = qFull(i, :);
%             mdl_old.forwardPosition();
            
            vis.update();
            pause(0.01);
        end
    end
end

function [progressVar, processSecondaryVar, precalcGradient] = calcWinLenAndH(trajT, trajX, trajU, dt, ioc, startInd, precalcGradient, trialInfo)
    lenTraj = size(trajX, 1);
    
    H1 = [];
    H2 = [];
    prevFullWinInds = [];
    currFullWinInds = [];
    
    % frameIndsFullRange
    frameIndsFullRange = (startInd-trialInfo.maxWinLen):(startInd+trialInfo.maxWinLen);
    frameIndsFullRange = frameIndsFullRange(frameIndsFullRange > 0);
    frameIndsFullRange = frameIndsFullRange(frameIndsFullRange <= trialInfo.frameInds(end)+trialInfo.maxWinLen);
    
    precalcGradient = precalculateGradient_pushpop(trajX, trajU, ioc, precalcGradient, frameIndsFullRange);

    % Expanding window length l
    % (Paper Sec. IV.A: adaptive window, inner loop increasing l(t))
    for i = 1:trialInfo.maxWinLen
        % determine the current window to check
        switch trialInfo.hWinAdvFlag
            case 'forward'
                currFullWinInds = startInd + (1:i);
                
            case 'backward'
                currFullWinInds = startInd - (1:i);
                
            case 'centre'
                addToRight = ceil((i-1)/2);
                addToLeft = ceil((i-2)/2);
                
                addInds = [-addToLeft:0 0:addToRight];
                uniInds = unique(addInds);
                currFullWinInds = uniInds + startInd + 1;
        end
        
        % error check on the win len
        currFullWinInds = currFullWinInds(currFullWinInds > 0);
        currFullWinInds = currFullWinInds(currFullWinInds <= lenTraj);
        
        currLen = length(currFullWinInds);
        currHRow = currLen*trialInfo.lenDof;
        
        if currLen < trialInfo.windowWidth
            switch trialInfo.displayInfo
                case 'verbose'
                    fprintf('Obs frames %i:%i, width not sufficient. \n', ...
                        currFullWinInds(1), currFullWinInds(end));
            end
            continue;
            
        elseif currHRow < trialInfo.hWant % run the inversion only when the window is properly sized
            switch trialInfo.displayInfo
                case 'verbose'
                    fprintf('Obs frames %i:%i, row to col ratio not sufficient. Have %u but want %u \n', ...
                        currFullWinInds(1), currFullWinInds(end), currHRow, trialInfo.hWant);
            end
            continue;   
        end
        
        % check the previous entry, if the first and last entry matches,
        % then we can just reuse the previous H1/H2 matrices instead of
        % recon a new one
        if ~isempty(prevFullWinInds) && length(currFullWinInds) > 1 &&...
                prevFullWinInds(1) == currFullWinInds(1) && ...
                prevFullWinInds(end) == currFullWinInds(end-1)
            % use the previous H1 and H2
        else
            H1 = [];
            H2 = [];
        end

        % Assemble recovery matrix
        % (Paper eqs. (10)–(12))
        % assemble H matrix
        [H, H1, H2] = assembleHMatrixWithPrecalc(H1, H2, currFullWinInds, precalcGradient);
%         [H, H1, H2] = assembleHMatrix(trajT, trajX, trajU, dt, ioc, H1, H2, currFullWinInds, trajH1, trajH2, trialInfo);
     
        prevFullWinInds = currFullWinInds;
        
        if currLen >= trialInfo.maxWinLen || max(currFullWinInds) == size(trajX, 1)
            hitMaxWinLen = 1;
        else
            hitMaxWinLen = 0;
        end

        % Check rank condition
        % (Paper eq. (18): l_min(t) found when rank(H) = r+n-1)
        % check H matrix for completion
        [progressVar] = checkHMatrix(H, currFullWinInds, trialInfo, hitMaxWinLen);
        
        if ~isempty(progressVar)
            processSecondaryVar.H1 = H1;
            processSecondaryVar.H2 = H2;
            processSecondaryVar.H = H;
%             processSecondaryVar.Hhat = Hhat; %  Hhat = H/norm(H,'fro');

            % Successful recovery (Paper Lemma 1, eq. (19))
            break;
        end
    end
end

function [H, H1, H2] = assembleHMatrix(trajT, trajX, trajU, dt, ioc, H1, H2, fullWinInds, trialInfo)
    if ~isempty(H1) 
        indsToRun = length(fullWinInds);
    else
        indsToRun = 1:length(fullWinInds);
    end
    
    for indSubFrame = indsToRun
        % start each individual window
        winInds = fullWinInds(1:indSubFrame);

        % Read next observation
        x = trajX(winInds, :);
        u = trajU(winInds, :);

        % Assemble the H matrix for this width
        [H1, H2] = getRecoveryMatrix(ioc, H1, H2, x, u, dt);
        H = [H1 -H2];
    end
end

function [df_dx, df_du, dp_dx, dp_du, x, u] = getGradient(trajX, trajU, incurrInd, ioc)   
    [x, u] = setDataLength(trajX, trajU, IOCInstanceNew.winSize, incurrInd);
    [fx, fu, px, pu] = ioc.getDerivativesNewObservation(x, u);
    df_dx = fx';
    df_du = fu';
    dp_dx = px';
    dp_du = pu'; 
end

function [H, H1, H2] = assembleHMatrixWithPrecalc(H1, H2, fullWinInds, precalcGradient)
    % need to recalculate H1/H2 using precalcs to the current timestep
    if isempty(H1)
        for indSubFrame = 1:length(fullWinInds)-1
            currFrame = fullWinInds(indSubFrame);
            [H1, H2] = assembleH1H2(precalcGradient(currFrame).df_dx, ...
                precalcGradient(currFrame).df_du, ...
                precalcGradient(currFrame).dp_dx, ...
                precalcGradient(currFrame).dp_du, H1, H2);
        end
    end
    
    % add the newest timestep to it
    currFrame = fullWinInds(end);
    [H1, H2] = assembleH1H2(precalcGradient(currFrame).df_dx, ...
        precalcGradient(currFrame).df_du, ...
        precalcGradient(currFrame).dp_dx, ...
        precalcGradient(currFrame).dp_du, H1, H2);

    % Uses precomputed ∂f/∂x, ∂f/∂u, ∂φ/∂x, ∂φ/∂u
    % to iteratively build H1, H2 (Paper eq. (14): iterative property)
    % Paper eq. (10)
    H = [H1 -H2];
end

function [progressVar] = checkHMatrix(H, fullWinInds, trialInfo, hitMaxWinLen)
    progressVar = [];

    % proceed with H matrix inversion
    % (Paper eq. (24): normalize H using Frobenius norm)
    Hhat = H/norm(H,'fro');

    % Compute weights using final recovery matrix
    % (Paper eq. (25): minimize ||H*[ω;λ]|| subject to sum ω = 1)
    [weights, ~] = computeWeights(Hhat, trialInfo.numWeights);
    % weightTraj(indFrame, :) = weights/sum(weights);

    % Compute error between true and recovered weights
    error = computeError(weights, trialInfo.trueWeights);
%     errorTraj(indFrame,:) = error;

    % save rank of recovery matrix
    [rank, completed, rankPassCode] = validateCompletion(Hhat, trialInfo.gamma, trialInfo.delta, trialInfo.dimWeights);

    if hitMaxWinLen
        completed = 1;
    end

%     rankTraj(currLen,:) = rank;
%     rankPassCodeTraj(currLen, :) = rankPassCode;

    switch trialInfo.displayInfo
        case 'verbose'
            % Display information
            fprintf('Obs frames %i:%i of max %u/%u, rank: %0.2f/%0.2f, error: %0.3f, code: %u,%u,%u ', ...
                fullWinInds(1), fullWinInds(end), length(fullWinInds), trialInfo.maxWinLen, rank, trialInfo.gamma, error(1), ...
                rankPassCode(1), rankPassCode(2), rankPassCode(3) );

            fprintf('Weights: ');
            for j = 1:trialInfo.numWeights
                fprintf('%+0.3f,', weights(j));
            end
            fprintf('\n');

        case 'final'
            if completed
                % Display information
                fprintf('Obs frames %i:%i of max %u/%u, rank: %0.2f/%0.2f, error: %0.3f, code: %u,%u,%u, ', ...
                    fullWinInds(1), fullWinInds(end), length(fullWinInds), trialInfo.maxWinLen, rank, trialInfo.gamma, error(1), ...
                    rankPassCode(1), rankPassCode(2), rankPassCode(3) );

                fprintf('Weights: ');
                for j = 1:trialInfo.numWeights
                    fprintf('%+0.3f,', weights(j));
                end
                fprintf('\n');
            end
    end
        
    if completed
        % Save recovered weights ω̂(t)
        % (Paper eq. (27): ω̂(t) = computed weights if l_min(t)<l_max, else carry over ω̂(t-1))


%         progressVar.Hhat = Hhat;
        progressVar.weights = weights'/sum(weights);
%         progressVar.winIndsStart = fullWinInds(1);
%         progressVar.winIndsEnd = fullWinInds(end);
        progressVar.winInds = [fullWinInds(1) fullWinInds(end)];
        progressVar.rankTraj = rank;
        progressVar.rankPass = rankPassCode;
        progressVar.error = error;
    end
end

function precalcGradient = precalculateGradient_initialize(trajX, trajU, ioc, frameInds, trialInfo)
    precalcGradient(frameInds(end)+trialInfo.maxWinLen).df_dx = []; % preallocating
    precalcGradient(frameInds(end)+trialInfo.maxWinLen).df_du = [];
    precalcGradient(frameInds(end)+trialInfo.maxWinLen).dp_dx = [];
    precalcGradient(frameInds(end)+trialInfo.maxWinLen).dp_du = [];
    
    for i = frameInds
        fprintf('Pre-calculating %uth H1/H2... \n', i);
        [tempGrad.df_dx, tempGrad.df_du, tempGrad.dp_dx, tempGrad.dp_du] = ...
            getGradient(trajX, trajU, i, ioc);
        
        precalcGradient(i) = tempGrad;
    end
end

function precalcGradient = precalculateGradient_pushpop(trajX, trajU, ioc, precalcGradient, frameInds)
    % pop the frame before
    priorInd = frameInds(1) - 1;
    if priorInd > 0
        precalcGradient(priorInd).df_dx = []; % preallocating
        precalcGradient(priorInd).df_du = [];
        precalcGradient(priorInd).dp_dx = [];
        precalcGradient(priorInd).dp_du = [];
    end
    
    % generate the new frame
    newFrameInd = frameInds(end)+1;
   
    [tempGrad.df_dx, tempGrad.df_du, tempGrad.dp_dx, tempGrad.dp_du] = ...
        getGradient(trajX, trajU, newFrameInd, ioc);
    
    precalcGradient(newFrameInd) = tempGrad;

    fprintf('Removed %uth H1/H2 and adding %uth H1/H2... ', priorInd, newFrameInd);
end
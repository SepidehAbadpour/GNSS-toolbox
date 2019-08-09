classdef SATPOS
    properties
        gnss (1,1) char
        ephType (1,:) char {mustBeMember(ephType,{'broadcast','precise'})} = 'broadcast';
        ephFolder (1,:) char
        ephList (1,:) cell
        satList (1,:) double

        gpstime (:,2) double
        ECEF (1,:) cell
        local (1,:) cell
        recpos (1,3) double = [0,0,0]
        satTimeFlags (:,:) logical
    end
    
    methods
        function obj = SATPOS(gnss,satList,ephType,ephFolder,gpstime,recpos,satTimeFlags)
            obj.gnss = gnss;
            obj.satList = satList;
            obj.ephType = ephType;
            obj.ephFolder = fullpath(ephFolder);
            obj.gpstime = gpstime;
            if nargin < 6
                obj.recpos = [0 0 0];
                obj.satTimeFlags = true(size(gpstime,1),numel(satList));
            end
            if nargin == 6
                obj.recpos = recpos;
                obj.satTimeFlags = true(size(gpstime,1),numel(satList));
            end
            if nargin == 7
               obj.recpos = recpos;
               obj.satTimeFlags = satTimeFlags;
            end
            timeFrame = gps2greg(gpstime([1,end],:));
            timeFrame = timeFrame(:,1:3);
            
            obj.ephList = prepareEph(gnss,ephType,ephFolder,timeFrame);
            switch ephType
                case 'broadcast'
                    brdc = loadRINEXNavigation(obj.gnss,obj.ephFolder,obj.ephList);
                    brdc = checkEphStatus(brdc);
                    
                    % Check if given sat and sat in brdc corresponds
                    selSatNotPresent = ~ismember(obj.satList,brdc.sat);
                    if any(selSatNotPresent)
                        notPresentSats = obj.satList(selSatNotPresent);
                        warning('Following sats are of %s system are not present in ephemeris: %s\nThese satellites will be removed from further processing.',obj.gnss,strjoin(strsplit(num2str(notPresentSats)),','))
                        obj.satList = obj.satList(~selSatNotPresent);
                        obj.satTimeFlags = obj.satTimeFlags(:,~selSatNotPresent);
                    end
                    if isempty(obj.satList)
                        warning('No satellites to process! Program will end.')
                        return
                    end
                    [obj.ECEF, obj.local] = SATPOS.getBroadcastPosition(obj.satList,obj.gpstime,brdc,obj.recpos,obj.satTimeFlags);
                    
                case 'precise'
                    fileListToLoad = cellfun(@(x) fullfile(obj.ephFolder,x),obj.ephList,'UniformOutput',false);
                    eph = SP3(fileListToLoad,900,gnss);
                    selSatNotPresent = ~ismember(obj.satList,eph.sat.(obj.gnss));
                    if any(selSatNotPresent)
                        notPresentSats = obj.satList(selSatNotPresent);
                        warning('Following sats are of %s system are not present in ephemeris: %s\nThese satellites will be removed from further processing.',obj.gnss,strjoin(strsplit(num2str(notPresentSats)),','))
                        obj.satList = obj.satList(~selSatNotPresent);
                        obj.satTimeFlags = obj.satTimeFlags(:,~selSatNotPresent);
                    end
                    if isempty(obj.satList)
                        warning('No satellites to process! Program will end.')
                        return
                    end
                    [obj.ECEF, obj.local] = SATPOS.getPrecisePosition(obj.satList,obj.gpstime,eph,obj.recpos,obj.satTimeFlags);
            end
        end
    end
    
    methods (Static)
        function [ECEF, local] = getBroadcastPosition(satList,gpstime,brdc,recpos,satTimeFlags)
            validateattributes(satList,{'double'},{'nonnegative'},1)
            validateattributes(gpstime,{'double'},{'size',[NaN,2]},2)
            validateattributes(brdc,{'struct'},{},3)
            if nargin < 4
                recpos = [0,0,0];
                satTimeFlags = true(size(gpstime,1),numel(satList));
            elseif nargin < 5
                satTimeFlags = true(size(gpstime,1),numel(satList));
            end
            validateattributes(recpos,{'double'},{'size',[1,3]},4)
            validateattributes(satTimeFlags,{'logical'},{'size',[size(gpstime,1),numel(satList)]},5)
                
            satsys =  brdc.gnss;
            fprintf('\n############################################################\n')
            fprintf('##### Load and compute satellite position for %s system #####\n',satsys)
            fprintf('############################################################\n')

            % Allocate satellite position (satpos) cells
            ECEF = cell(1,numel(satList));
            local = cell(1,numel(satList));
            ECEF(:) = {zeros(size(gpstime,1),3)};
            local(:) = {zeros(size(gpstime,1),3)};
            
            % Looping throught all satellites in observation file
            fprintf('>>> Computing satellite positions >>>\n')
            selSatNotPresent = ~ismember(satList,brdc.sat);
            if any(selSatNotPresent)
                notPresentSats = satList(selSatNotPresent);
                warning('Following sats of %s system are not present in ephemeris: %s\nThese satellites will be removed from further processing.',satsys,strjoin(strsplit(num2str(notPresentSats)),','))
                satList = satList(~selSatNotPresent);
                satTimeFlags = satTimeFlags(:,~selSatNotPresent);
            end
            if isempty(satList)
                warning('No satellites to process! Program will end.')
                return 
            end
            nSats = length(satList);
            for i = 1:nSats
                PRN = satList(i);
                fprintf(' -> computing satellite %s%02d ',satsys,PRN);
                
                % Selection of only non-zero epochs
                PRNtimeSel = satTimeFlags(:,i);
                selEph = brdc.sat == PRN;
                if sum(selEph) == 0
                    fprintf('(skipped - missing ephemeris for satellite)\n');
                    continue;
                end
                
                PRNephAll = brdc.eph{selEph};
                ecef = zeros(nnz(PRNtimeSel),3);
                
                % Time variables
                GPSTimeWanted = gpstime(PRNtimeSel,:);
                mTimeWanted   = gps2matlabtime(GPSTimeWanted);
                mTimeGiven    = PRNephAll(11,:)';
                
                % In case of GLONASS -> change mTimeWanted to UTC.
                % Values of mTimeGiven are from BRDC message and these are already in UTC timescale.
                % Also value of GPS week and GPS second of week will be transformed to UTC time.
                if satsys == 'R'
                    mTimeWanted   = mTimeWanted - brdc.hdr.leapSeconds/86400;
                    GLOTimeWanted = GPS2UTCtime(GPSTimeWanted,brdc.hdr.leapSeconds);
                end
                
                % In case of BEIDOU/COMPASS -> change mTimeWanted to UTC at 1.1.2006.
                % Values of mTimeGiven are from BRDC message and these are already in UTC timescale.
                % Also value of GPS week and GPS second of week will be transformed to BDT time.
                if satsys == 'C'
                    mTimeWanted   = mTimeWanted - 14/86400;
                    BDSTimeWanted = GPS2UTCtime(GPSTimeWanted,14);
                end
                
                % Find previous epochs and throw error if there are NaN values
                ageCritical = getEphCriticalAge(satsys);
                [ephAge, idxEpoch] = getEphReferenceEpoch(satsys,mTimeWanted,mTimeGiven,ageCritical);
                if all(isnan(idxEpoch))
                    fprintf('(skipped - missing previous ephemeris)\n');
                    continue;
                else
                    percNotSuitableEpochs = (sum(ephAge >= ageCritical)/length(ephAge))*100;
                    if percNotSuitableEpochs ~= 0
                        fprintf('(%.1f%% epochs not computed - old ephemeris age)',percNotSuitableEpochs)
                    end
                end
                
                % Compute satellite position for group of intervals related to common ephemeris block
                uniqueIdxEpoch = unique(idxEpoch);
                uniqueIdxEpoch(isnan(uniqueIdxEpoch)) = [];
                for j = 1:length(uniqueIdxEpoch)
                    selTime = uniqueIdxEpoch(j) == idxEpoch;
                    GPStime = GPSTimeWanted(selTime,:);
                    eph     = PRNephAll(:,uniqueIdxEpoch(j));
                    
                    % Select function according to satellite system
                    switch satsys
                        case 'G'
                            ecef = getSatPosGPS(GPStime,eph);
                        case 'R'
                            GLOtime = GLOTimeWanted(selTime,:);
                            ecef = getSatPosGLO(GLOtime,eph)';
                        case 'E'
                            ecef = getSatPosGAL(GPStime,eph);
                        case 'C'
                            BDStime = BDSTimeWanted(selTime,:);
                            ecef = getSatPosBDS(BDStime,eph);
                    end
                    temp = ECEF{i}(PRNtimeSel,:);
                    temp(selTime,:) = ecef;
                    ECEF{i}(PRNtimeSel,:) = temp;
                    
                    % Compute azimuth, alevation and slant range
                    if ~isequal(recpos,[0 0 0])
                        ell = referenceEllipsoid('wgs84');
                        [lat0,lon0,h0] = ecef2geodetic(recpos(1),recpos(2),recpos(3),ell,'degrees');
                        [azi,elev, slantRange] = ecef2aer(ecef(:,1),ecef(:,2),ecef(:,3),lat0,lon0,h0,ell);
                        temp = local{i}(PRNtimeSel,:);
                        temp(selTime,:) = [elev, azi, slantRange];
                        local{i}(PRNtimeSel,:) = temp;
                    end
                end

                if sum(sum([ECEF{i}, local{i}])) ~= 0
                    fprintf('(done)\n');
                end
            end
            
%             % Clear ECEF, local cells -> remove satellites without computed position
%             selNotComputedPositions = cellfun(@(x) sum(sum(x)) == 0, ECEF);
%             obsrnx.satpos.(satsys)(selNotComputedPositions) = [];
%             obsrnx.sat.(satsys)(selNotComputedPositions) = [];
%             obsrnx.obs.(satsys)(selNotComputedPositions) = [];
%             obsrnx.obsqi.(satsys)(selNotComputedPositions) = [];

        end
        function [ECEF, local] = getPrecisePosition(satList,gpstime,eph,recpos,satTimeFlags)
            validateattributes(satList,{'double'},{'nonnegative'},1)
            validateattributes(gpstime,{'double'},{'size',[NaN,2]},2)
            validateattributes(eph,{'SP3'},{'size',[1,1]},3)
            if nargin < 4
                recpos = [0,0,0];
                satTimeFlags = true(size(gpstime,1),numel(satList));
            elseif nargin < 5
                satTimeFlags = true(size(gpstime,1),numel(satList));
            end
            validateattributes(recpos,{'double'},{'size',[1,3]},4)
            validateattributes(satTimeFlags,{'logical'},{'size',[size(gpstime,1),numel(satList)]},5)
                
            satsys =  eph.gnss;
            assert(numel(satsys)==1,'Method "SATPOS.getPrecisePosition" is limited to run with single satellite system!');
            fprintf('\n############################################################\n')
            fprintf('##### Load and compute satellite position for %s system #####\n',satsys)
            fprintf('############################################################\n')

            % Allocate satellite position (satpos) cells
            ECEF = cell(1,numel(satList));
            local = cell(1,numel(satList));
            ECEF(:) = {zeros(size(gpstime,1),3)};
            local(:) = {zeros(size(gpstime,1),3)};
            
            % Looping throught all satellites in observation file
            fprintf('>>> Computing satellite positions >>>\n')
            selSatNotPresent = ~ismember(satList,eph.sat.(satsys));
            if any(selSatNotPresent)
                notPresentSats = satList(selSatNotPresent);
                warning('Following sats of %s system are not present in ephemeris: %s\nThese satellites will be removed from further processing.',...
                    satsys,strjoin(strsplit(num2str(notPresentSats)),','))
                satList = satList(~selSatNotPresent);
                satTimeFlags = satTimeFlags(:,~selSatNotPresent);
            end
            if isempty(satList)
                warning('No satellites to process! Program will end.')
                return 
            end
            nSats = length(satList);
            for i = 1:nSats
                PRN = satList(i);
                fprintf(' -> computing satellite %s%02d ',satsys,PRN);
                
                % Selection of only non-zero epochs
                PRNtimeSel = satTimeFlags(:,i);
                selEph = eph.sat.(satsys) == PRN;
                if nnz(selEph) == 0
                    fprintf('(skipped - missing ephemeris for satellite)\n');
                    continue;
                end
                PRNephAll = eph.pos.(satsys){selEph};
                ecef = zeros(nnz(PRNtimeSel),3);
                
                % Time variables
                GPSTimeWanted = gpstime(PRNtimeSel,:);
                mTimeWanted   = gps2matlabtime(GPSTimeWanted);
                mTimeGiven    = eph.t(:,9);
                
                % In case of GLONASS -> change mTimeWanted to UTC.
                % Values of mTimeGiven are from BRDC message and these are already in UTC timescale.
                % Also value of GPS week and GPS second of week will be transformed to UTC time.
                if satsys == 'R'
                    mTimeWanted   = mTimeWanted - brdc.hdr.leapSeconds/86400;
                    GLOTimeWanted = GPS2UTCtime(GPSTimeWanted,brdc.hdr.leapSeconds);
                end
                
                % In case of BEIDOU/COMPASS -> change mTimeWanted to UTC at 1.1.2006.
                % Values of mTimeGiven are from BRDC message and these are already in UTC timescale.
                % Also value of GPS week and GPS second of week will be transformed to BDT time.
                if satsys == 'C'
                    mTimeWanted   = mTimeWanted - 14/86400;
                    BDSTimeWanted = GPS2UTCtime(GPSTimeWanted,14);
                end
            end
        end
    end
end
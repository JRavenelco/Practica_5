classdef LACShaker < handle
    %LACShaker  Control the Actuonix LAC + L12 actuator as a shaker.
    %
    %   Communicates with the LAC board via USB (mpusbapi.dll) using Python
    %   as a bridge.  Generates sinusoidal, chirp, or step excitation.
    %
    %   Prerequisites:
    %     1. Python with the project venv active (detected automatically)
    %     2. Actuonix LAC Configuration Utility installed (provides mpusbapi.dll)
    %     3. LAC board connected via USB and powered
    %
    %   Quick start:
    %     shaker = LACShaker();
    %     shaker.connect();
    %     shaker.move(50);           % go to 50%
    %     shaker.sine(1.0, 40, 10);  % 1 Hz, 40% amp, 10 s
    %     shaker.disconnect();
    %
    %   With PicoPendulumReader:
    %     reader = PicoPendulumReader('Host','192.168.17.54');
    %     shaker = LACShaker();
    %     shaker.connect();
    %     shaker.startSine(1.0, 40);       % start continuous oscillation
    %     % ... acquire data with reader.step() ...
    %     shaker.stop();
    %     shaker.disconnect();

    properties
        StrokeMM     double = 50.0     % Actuator stroke (mm)
        UpdateHz     double = 50       % Position command rate (Hz)
        CenterPct    double = 50.0     % Rest/center position (%)
        VID          uint16 = 0       % USB Vendor ID (0 = default 0x04D8)
        PID          uint16 = 0       % USB Product ID (0 = default 0xFC5A)
    end

    properties (Access = private)
        lac                            % Python LACController object
        timerObj                       % timer for continuous oscillation
        phase        double = 0
        shakeFreq    double = 1.0
        shakeAmp     double = 50.0
        isConnected  logical = false
    end

    methods
        function obj = LACShaker(varargin)
            %LACShaker  Create shaker controller.
            %   s = LACShaker('StrokeMM', 50, 'CenterPct', 50)
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
        end

        function connect(obj)
            %CONNECT  Open USB connection to the LAC board.
            toolsDir = fileparts(mfilename('fullpath'));
            if count(py.sys.path, toolsDir) == 0
                insert(py.sys.path, int32(0), toolsDir);
            end
            % Also add the tools/ subdirectory
            toolsSubDir = fullfile(toolsDir, 'tools');
            if isfolder(toolsSubDir) && count(py.sys.path, toolsSubDir) == 0
                insert(py.sys.path, int32(0), toolsSubDir);
            end

            kwargs = {};
            if obj.VID > 0
                kwargs = [kwargs, {'vid', int32(obj.VID)}];
            end
            if obj.PID > 0
                kwargs = [kwargs, {'pid', int32(obj.PID)}];
            end

            obj.lac = py.lac_controller.LACController(pyargs(kwargs{:}));
            obj.lac.open();
            obj.lac.set_speed(int32(1023));
            obj.isConnected = true;
            fprintf('[LACShaker] Connected (stroke=%gmm, center=%.1f%%)\n', ...
                obj.StrokeMM, obj.CenterPct);
        end

        function disconnect(obj)
            %DISCONNECT  Stop oscillation, retract, and close USB connection.
            obj.stopTimer();
            if obj.isConnected
                try
                    obj.lac.set_position_pct(0.0);
                    pause(2.0);
                catch
                end
                obj.lac.close();
                obj.isConnected = false;
                fprintf('[LACShaker] Disconnected\n');
            end
        end

        function delete(obj)
            obj.disconnect();
        end

        % ── Static positioning ──────────────────────────────────────────
        function move(obj, positionPct)
            %MOVE  Move to static position (0–100%).
            obj.stopTimer();
            obj.lac.set_position_pct(positionPct);
        end

        function center(obj)
            %CENTER  Return to center position.
            obj.move(obj.CenterPct);
        end

        function pos = feedback(obj)
            %FEEDBACK  Read current actuator position (%).
            raw = double(obj.lac.get_feedback());
            pos = raw / 1023.0 * 100.0;
        end

        function mm = feedbackMM(obj)
            %FEEDBACKMM  Read current position in mm.
            raw = double(obj.lac.get_feedback());
            mm = raw / 1023.0 * obj.StrokeMM;
        end

        % ── Blocking oscillation ────────────────────────────────────────
        function sine(obj, freqHz, amplitudePct, durationS)
            %SINE  Run sinusoidal oscillation (blocking).
            %   shaker.sine(1.0, 40, 10)  — 1 Hz, 40% amp, 10 seconds
            obj.stopTimer();
            dt = 1.0 / obj.UpdateHz;
            halfAmp = amplitudePct / 2.0;
            ctr = obj.CenterPct;
            N = round(durationS * obj.UpdateHz);
            fprintf('[LACShaker] Sine: %.2f Hz, amp=%.1f%%, %.1fs\n', ...
                freqHz, amplitudePct, durationS);
            t0 = tic;
            for k = 0:N-1
                t = k * dt;
                pos = ctr + halfAmp * sin(2*pi*freqHz*t);
                pos = max(0, min(100, pos));
                obj.lac.set_position_pct(pos);
                elapsed = toc(t0);
                target = (k+1) * dt;
                if target > elapsed
                    pause(target - elapsed);
                end
            end
            obj.lac.set_position_pct(ctr);
            fprintf('[LACShaker] Sine complete\n');
        end

        function chirp(obj, freqStart, freqEnd, amplitudePct, durationS)
            %CHIRP  Run frequency sweep (blocking).
            %   shaker.chirp(0.5, 5.0, 40, 60)
            obj.stopTimer();
            dt = 1.0 / obj.UpdateHz;
            halfAmp = amplitudePct / 2.0;
            ctr = obj.CenterPct;
            rate = (freqEnd - freqStart) / durationS;
            N = round(durationS * obj.UpdateHz);
            fprintf('[LACShaker] Chirp: %.2f→%.2f Hz, amp=%.1f%%, %.1fs\n', ...
                freqStart, freqEnd, amplitudePct, durationS);
            t0 = tic;
            for k = 0:N-1
                t = k * dt;
                phase = 2*pi*(freqStart*t + 0.5*rate*t^2);
                pos = ctr + halfAmp * sin(phase);
                pos = max(0, min(100, pos));
                obj.lac.set_position_pct(pos);
                elapsed = toc(t0);
                target = (k+1) * dt;
                if target > elapsed
                    pause(target - elapsed);
                end
            end
            obj.lac.set_position_pct(ctr);
            fprintf('[LACShaker] Chirp complete\n');
        end

        % ── Non-blocking oscillation (timer-based) ──────────────────────
        function startSine(obj, freqHz, amplitudePct)
            %STARTSINE  Start continuous sinusoidal oscillation (non-blocking).
            %   Use with PicoPendulumReader for simultaneous acquisition.
            %   Call shaker.stop() to end.
            obj.stopTimer();
            obj.shakeFreq = freqHz;
            obj.shakeAmp = amplitudePct;
            obj.phase = 0;
            period = 1.0 / obj.UpdateHz;
            obj.timerObj = timer( ...
                'ExecutionMode', 'fixedRate', ...
                'Period', period, ...
                'TimerFcn', @(~,~) obj.timerCallback());
            start(obj.timerObj);
            fprintf('[LACShaker] Oscillation started: %.2f Hz, amp=%.1f%%\n', ...
                freqHz, amplitudePct);
        end

        function stop(obj)
            %STOP  Stop oscillation and return to center.
            obj.stopTimer();
            if obj.isConnected
                obj.lac.set_position_pct(obj.CenterPct);
            end
        end
    end

    methods (Access = private)
        function timerCallback(obj)
            dt = 1.0 / obj.UpdateHz;
            obj.phase = obj.phase + 2*pi*obj.shakeFreq*dt;
            if obj.phase >= 2*pi
                obj.phase = obj.phase - 2*pi;
            end
            halfAmp = obj.shakeAmp / 2.0;
            pos = obj.CenterPct + halfAmp * sin(obj.phase);
            pos = max(0, min(100, pos));
            try
                obj.lac.set_position_pct(pos);
            catch
            end
        end

        function stopTimer(obj)
            if ~isempty(obj.timerObj)
                stop(obj.timerObj);
                delete(obj.timerObj);
                obj.timerObj = [];
            end
        end
    end
end

classdef LACActuatorBlock < matlab.System
    %LACActuatorBlock  Simulink System block for Actuonix LAC + L12 actuator.
    %
    %   Input:  positionPct (double, 0–100%)  — desired actuator position
    %   Output: feedbackPct (double, 0–100%)  — measured actuator position
    %
    %   Uses Python pyusb bridge to communicate with the LAC board via USB.
    %
    %   Usage in Simulink:
    %     1. Add a "MATLAB System" block and set it to LACActuatorBlock
    %     2. Connect a signal source (e.g., Sine Wave) to the input
    %     3. Connect the output to a Scope or To Workspace block
    %     4. Configure properties (rate, stroke, center) in the block mask
    %
    %   Example with Signal Builder:
    %     - Sine Wave block: Amplitude=20, Bias=50, Frequency=2*pi*1
    %       This gives 1 Hz oscillation between 30% and 70%

    properties (Nontunable)
        Rate         double = 50       % Command rate (Hz) — sets sample time
        StrokeMM     double = 50.0     % Actuator stroke length (mm)
        VID          uint16 = 0        % USB Vendor ID (0 = default 0x04D8)
        PID          uint16 = 0        % USB Product ID (0 = default 0xFC5F)
        RetractOnStop logical = true   % Retract to 0% when simulation stops
    end

    properties (Access = private)
        lac                            % Python LACController object
    end

    methods
        function obj = LACActuatorBlock(varargin)
            setProperties(obj, nargin, varargin{:});
        end
    end

    methods (Access = protected)
        function setupImpl(obj)
            % Add tools/ to Python path
            rootDir = fileparts(mfilename('fullpath'));
            toolsDir = fullfile(rootDir, 'tools');
            if count(py.sys.path, toolsDir) == 0
                insert(py.sys.path, int32(0), toolsDir);
            end

            % Build constructor kwargs
            kwargs = {};
            if obj.VID > 0
                kwargs = [kwargs, {'vid', int32(obj.VID)}];
            end
            if obj.PID > 0
                kwargs = [kwargs, {'pid', int32(obj.PID)}];
            end

            % Connect
            obj.lac = py.lac_controller.LACController(pyargs(kwargs{:}));
            obj.lac.open();
            obj.lac.set_speed(int32(1023));
            fprintf('[LACActuatorBlock] Connected (stroke=%gmm, rate=%dHz)\n', ...
                obj.StrokeMM, obj.Rate);
        end

        function feedbackPct = stepImpl(obj, positionPct)
            % Clamp input to valid range
            pos = max(0, min(100, positionPct));
            obj.lac.set_position_pct(pos);

            % Read feedback
            raw = double(obj.lac.get_feedback());
            feedbackPct = raw / 1023.0 * 100.0;
        end

        function releaseImpl(obj)
            if ~isempty(obj.lac)
                try
                    if obj.RetractOnStop
                        obj.lac.set_position_pct(0.0);
                        pause(2.0);
                    end
                catch
                end
                try
                    obj.lac.close();
                catch
                end
                obj.lac = [];
                fprintf('[LACActuatorBlock] Disconnected\n');
            end
        end

        function resetImpl(obj) %#ok<MANU>
            % Nothing to reset
        end

        % ── Port definitions ────────────────────────────────────────────
        function n = getNumInputsImpl(~)
            n = 1;
        end

        function n = getNumOutputsImpl(~)
            n = 1;
        end

        function sz = getOutputSizeImpl(~)
            sz = [1 1];
        end

        function dt = getOutputDataTypeImpl(~)
            dt = "double";
        end

        function c = isOutputComplexImpl(~)
            c = false;
        end

        function f = isOutputFixedSizeImpl(~)
            f = true;
        end

        function sts = getSampleTimeImpl(obj)
            sts = createSampleTime(obj, ...
                'Type', 'Discrete', ...
                'SampleTime', 1 / obj.Rate);
        end
    end

    methods (Static, Access = protected)
        function simMode = getSimulateUsingImpl
            simMode = "Interpreted execution";
        end

        function flag = showSimulateUsingImpl
            flag = false;
        end
    end
end

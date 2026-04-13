classdef PicoPendulumReader < matlab.System
    properties (Nontunable)
        Host = "192.168.17.54";
        Port = 4242;
        Rate = 200;
        Timeout = 10;
        StartOnSetup = true;
    end

    properties (Access = private)
        tcp
    end

    methods
        function obj = PicoPendulumReader(varargin)
            setProperties(obj, nargin, varargin{:});
        end
    end

    methods (Access = protected)
        function setupImpl(obj)
            obj.tcp = tcpclient(char(obj.Host), obj.Port, "Timeout", obj.Timeout);
            configureTerminator(obj.tcp, "LF");
            pause(1);
            obj.drainBuffer();

            ack = obj.sendCommand(sprintf("RATE %d", obj.Rate));
            if ~startsWith(ack, "OK RATE")
                error("PicoPendulumReader:Rate", "No se pudo configurar RATE. Respuesta: %s", ack);
            end

            if obj.StartOnSetup
                ack = obj.sendCommand("START");
                if ~strcmp(ack, "OK START")
                    error("PicoPendulumReader:Start", "No se pudo iniciar streaming. Respuesta: %s", ack);
                end
            end
        end

        function [t, ax, ay, az, gx, gy, gz, mx, my, mz] = stepImpl(obj)
            line = obj.readSampleLine();

            values = sscanf(line, "%f,%f,%f,%f,%f,%f,%f,%f,%f,%f");
            if numel(values) ~= 10
                error("PicoPendulumReader:Parse", "Trama inválida recibida: %s", line);
            end

            t = double(values(1)) / 1000.0;
            ax = double(values(2));
            ay = double(values(3));
            az = double(values(4));
            gx = double(values(5));
            gy = double(values(6));
            gz = double(values(7));
            mx = double(values(8));
            my = double(values(9));
            mz = double(values(10));
        end

        function releaseImpl(obj)
            if ~isempty(obj.tcp)
                try
                    writeline(obj.tcp, "STOP");
                catch
                end
                clear obj.tcp
                obj.tcp = [];
            end
        end

        function resetImpl(obj)
            if ~isempty(obj.tcp)
                flush(obj.tcp);
            end
        end

        function n = getNumInputsImpl(~)
            n = 0;
        end

        function n = getNumOutputsImpl(~)
            n = 10;
        end

        function [sz1, sz2, sz3, sz4, sz5, sz6, sz7, sz8, sz9, sz10] = getOutputSizeImpl(~)
            sz1 = [1 1];
            sz2 = [1 1];
            sz3 = [1 1];
            sz4 = [1 1];
            sz5 = [1 1];
            sz6 = [1 1];
            sz7 = [1 1];
            sz8 = [1 1];
            sz9 = [1 1];
            sz10 = [1 1];
        end

        function [dt1, dt2, dt3, dt4, dt5, dt6, dt7, dt8, dt9, dt10] = getOutputDataTypeImpl(~)
            dt1 = "double";
            dt2 = "double";
            dt3 = "double";
            dt4 = "double";
            dt5 = "double";
            dt6 = "double";
            dt7 = "double";
            dt8 = "double";
            dt9 = "double";
            dt10 = "double";
        end

        function [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10] = isOutputComplexImpl(~)
            c1 = false;
            c2 = false;
            c3 = false;
            c4 = false;
            c5 = false;
            c6 = false;
            c7 = false;
            c8 = false;
            c9 = false;
            c10 = false;
        end

        function [f1, f2, f3, f4, f5, f6, f7, f8, f9, f10] = isOutputFixedSizeImpl(~)
            f1 = true;
            f2 = true;
            f3 = true;
            f4 = true;
            f5 = true;
            f6 = true;
            f7 = true;
            f8 = true;
            f9 = true;
            f10 = true;
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

    methods (Access = private)
        function drainBuffer(obj)
            % Vaciar todo lo pendiente en el buffer TCP
            while obj.tcp.NumBytesAvailable > 0
                read(obj.tcp, obj.tcp.NumBytesAvailable);
                pause(0.05);
            end
        end

        function ack = sendCommand(obj, command)
            writeline(obj.tcp, command);
            while true
                line = strtrim(readline(obj.tcp));
                if strlength(line) == 0
                    continue;
                end
                if ~strcmp(line, "OK READY")
                    ack = line;
                    return;
                end
            end
        end

        function line = readSampleLine(obj)
            while true
                line = strtrim(readline(obj.tcp));
                if strlength(line) == 0
                    continue;
                end
                if ~startsWith(line, "OK") && ~startsWith(line, "ERR") && ~strcmp(line, "PONG")
                    return;
                end
            end
        end
    end
end

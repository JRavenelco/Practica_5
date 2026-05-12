classdef MobileMATLABReader < matlab.System
    % MobileMATLABReader Lee sensores de MATLAB Mobile desde Simulink.
    %
    % Use este System Object dentro de un bloque "MATLAB System".
    %
    % Salidas:
    %   t     tiempo relativo [s]
    %   ax    aceleracion x [m/s^2]
    %   ay    aceleracion y [m/s^2]
    %   az    aceleracion z [m/s^2]
    %   gx    velocidad angular x [rad/s]
    %   gy    velocidad angular y [rad/s]
    %   gz    velocidad angular z [rad/s]
    %   yaw   orientacion yaw [deg]
    %   pitch orientacion pitch [deg]
    %   roll  orientacion roll [deg]
    %
    % Notas de implementacion:
    %   - Lecturas instantaneas (Acceleration, AngularVelocity,
    %     Orientation) en lugar de logs; evita arreglos crecientes.
    %   - discardlogs periodico para mantener bajo el buffer interno.
    %   - Sin pause() en el camino caliente.
    %   - connectPhone es singleton-safe: limpia handles mobiledev colgados
    %     en el base workspace antes de crear uno nuevo.
    %   - Detector de cache congelado: si ningun sensor cambia su valor por
    %     NoDataTimeout segundos, se asume stream muerto y se fuerza
    %     reconexion.
    %   - discardlogs no marca desconexion en fallo transitorio.
    %   - Log de debug con fid persistente (un fopen total, no por step).
    %   - Tracker de jitter: mide dt entre cambios reales de valor y emite
    %     una linea STATS cada JitterReportPeriod segundos con el rate
    %     efectivo del telefono (no del step de Simulink).

    properties (Nontunable)
        Rate = 20;                     % Frecuencia de muestreo de Simulink [Hz]
        UseOrientation = true;         % Leer yaw/pitch/roll
        WarnIfNoData = true;           % Avisar si no llega ninguna muestra
        AutoReconnect = true;          % Reintentar mobiledev si se cae
        ReconnectPeriod = 5;           % Tiempo minimo entre reintentos [s]
        LogPurgePeriod = 5;            % discardlogs cada N segundos [s]
        NoDataTimeout = 5;             % Cache congelado por N seg => reconectar [s]
        ForceReconnectOnStale = true;  % Activar detector de cache congelado
        CleanupBaseWorkspace = true;   % Limpiar handles mobiledev del base ws
        EnableDebugLog = true;         % Guardar eventos de diagnostico
        DebugLogFile = "mobilematlab_reader_debug.log";
        DebugSamplePeriod = 2;         % Guardar SAMPLE cada N segundos [s]
        JitterReportPeriod = 5;        % Guardar STATS de jitter cada N seg [s]
    end

    properties (Access = private)
        phone
        startTime
        lastWarnTime
        lastReconnectTime
        lastPurgeTime
        lastSampleTime
        lastValueChangeTime
        lastDebugSampleTime
        isConnected

        % File handle persistente para el log de debug
        debugFid

        % Tracker de jitter (dt entre cambios reales de valor)
        jitter_prevT
        jitter_dtMin
        jitter_dtMax
        jitter_dtSum
        jitter_dtCount
        lastJitterReportTime

        last_ax
        last_ay
        last_az
        last_gx
        last_gy
        last_gz
        last_yaw
        last_pitch
        last_roll

        prev_ax
        prev_ay
        prev_az
        prev_gx
        prev_gy
        prev_gz
        prev_yaw
        prev_pitch
        prev_roll
    end

    methods
        function obj = MobileMATLABReader(varargin)
            setProperties(obj, nargin, varargin{:});
        end
    end

    methods (Access = protected)
        function setupImpl(obj)
            obj.startTime = tic;
            obj.resetState();
            obj.openDebugLog();
            obj.connectPhone();
        end

        function [t, ax, ay, az, gx, gy, gz, yaw, pitch, roll] = stepImpl(obj)
            t = toc(obj.startTime);

            if obj.isConnected
                try
                    obj.readInstant(t);

                    if (t - obj.lastPurgeTime) >= obj.LogPurgePeriod
                        try
                            discardlogs(obj.phone);
                            obj.logEvent("PURGE", "discardlogs OK");
                        catch ME
                            obj.logEvent("PURGE_WARN", ME.message);
                        end
                        obj.lastPurgeTime = t;
                    end

                    % Reporte periodico de jitter / rate efectivo
                    if (t - obj.lastJitterReportTime) >= obj.JitterReportPeriod
                        obj.emitJitterReport(t);
                    end

                    if obj.ForceReconnectOnStale ...
                            && obj.lastValueChangeTime > 0 ...
                            && (t - obj.lastValueChangeTime) > obj.NoDataTimeout
                        obj.logEvent("STALE_CACHE", sprintf( ...
                            "valores congelados por %.2f s; forzando reconexion", ...
                            t - obj.lastValueChangeTime));
                        obj.warnThrottled("MobileMATLABReader:StaleCache", ...
                            sprintf("Valores constantes por %.1f s; reconectando.", ...
                            t - obj.lastValueChangeTime), t);
                        obj.cleanupOwnPhone();
                        obj.isConnected = false;
                    elseif obj.WarnIfNoData ...
                            && obj.lastSampleTime > 0 ...
                            && (t - obj.lastSampleTime) > obj.NoDataTimeout
                        obj.warnThrottled("MobileMATLABReader:Stale", ...
                            sprintf("Sin muestras nuevas por %.1f s.", ...
                            t - obj.lastSampleTime), t);
                        obj.logEvent("STALE", sprintf("%.3f s sin lecturas validas", ...
                            t - obj.lastSampleTime));
                    end
                catch ME
                    obj.isConnected = false;
                    obj.cleanupOwnPhone();
                    obj.logEvent("DISCONNECTED", ME.message);
                    obj.warnThrottled("MobileMATLABReader:Disconnected", ...
                        sprintf("Se perdio MATLAB Mobile (%s).", ME.message), t);
                end
            end

            if ~obj.isConnected && obj.AutoReconnect
                obj.tryReconnect(t);
            end

            ax = obj.last_ax;
            ay = obj.last_ay;
            az = obj.last_az;
            gx = obj.last_gx;
            gy = obj.last_gy;
            gz = obj.last_gz;
            yaw = obj.last_yaw;
            pitch = obj.last_pitch;
            roll = obj.last_roll;
        end

        function releaseImpl(obj)
            if ~isempty(obj.phone)
                try
                    obj.phone.Logging = 0;
                catch
                end
                obj.logEvent("RELEASE", "Logging=0; delete(phone)");
                try
                    delete(obj.phone);
                catch
                end
                obj.phone = [];
            end
            obj.isConnected = false;
            % Cierre defensivo del log
            obj.closeDebugLog();
        end

        function resetImpl(obj)
            obj.startTime = tic;
            obj.resetState();

            if obj.isConnected && ~isempty(obj.phone) && isvalid(obj.phone)
                try
                    discardlogs(obj.phone);
                    obj.phone.Logging = 1;
                    obj.logEvent("RESET", "discardlogs OK, Logging=1");
                catch ME
                    obj.cleanupOwnPhone();
                    obj.isConnected = false;
                    obj.logEvent("RESET_FAIL", ME.message);
                end
            elseif obj.AutoReconnect
                obj.connectPhone();
            end
        end

        function n = getNumInputsImpl(~)
            n = 0;
        end

        function n = getNumOutputsImpl(~)
            n = 10;
        end

        function [sz1, sz2, sz3, sz4, sz5, sz6, sz7, sz8, sz9, sz10] = getOutputSizeImpl(~)
            sz1 = [1 1]; sz2 = [1 1]; sz3 = [1 1]; sz4 = [1 1]; sz5 = [1 1];
            sz6 = [1 1]; sz7 = [1 1]; sz8 = [1 1]; sz9 = [1 1]; sz10 = [1 1];
        end

        function [dt1, dt2, dt3, dt4, dt5, dt6, dt7, dt8, dt9, dt10] = getOutputDataTypeImpl(~)
            dt1 = "double"; dt2 = "double"; dt3 = "double"; dt4 = "double"; dt5 = "double";
            dt6 = "double"; dt7 = "double"; dt8 = "double"; dt9 = "double"; dt10 = "double";
        end

        function [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10] = isOutputComplexImpl(~)
            c1 = false; c2 = false; c3 = false; c4 = false; c5 = false;
            c6 = false; c7 = false; c8 = false; c9 = false; c10 = false;
        end

        function [f1, f2, f3, f4, f5, f6, f7, f8, f9, f10] = isOutputFixedSizeImpl(~)
            f1 = true; f2 = true; f3 = true; f4 = true; f5 = true;
            f6 = true; f7 = true; f8 = true; f9 = true; f10 = true;
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
        function resetState(obj)
            obj.lastWarnTime = -inf;
            obj.lastReconnectTime = -inf;
            obj.lastPurgeTime = 0;
            obj.lastSampleTime = 0;
            obj.lastValueChangeTime = 0;
            obj.lastDebugSampleTime = -inf;
            obj.isConnected = false;

            % Jitter
            obj.jitter_prevT = NaN;
            obj.jitter_dtMin = NaN;
            obj.jitter_dtMax = NaN;
            obj.jitter_dtSum = 0;
            obj.jitter_dtCount = 0;
            obj.lastJitterReportTime = 0;

            obj.last_ax = 0; obj.last_ay = 0; obj.last_az = 0;
            obj.last_gx = 0; obj.last_gy = 0; obj.last_gz = 0;
            obj.last_yaw = 0; obj.last_pitch = 0; obj.last_roll = 0;

            obj.prev_ax = NaN; obj.prev_ay = NaN; obj.prev_az = NaN;
            obj.prev_gx = NaN; obj.prev_gy = NaN; obj.prev_gz = NaN;
            obj.prev_yaw = NaN; obj.prev_pitch = NaN; obj.prev_roll = NaN;
        end

        % ---- Debug log con fid persistente ----

        function openDebugLog(obj)
            obj.debugFid = -1;
            if ~obj.EnableDebugLog
                return;
            end
            try
                if strlength(obj.DebugLogFile) == 0
                    return;
                end
                obj.debugFid = fopen(char(obj.DebugLogFile), 'a');
                if obj.debugFid > 0
                    % Cabecera de sesion (util para separar runs)
                    try
                        fprintf(obj.debugFid, ...
                            '# --- session start %s ---\n', ...
                            datestr(now, 'yyyy-mm-dd HH:MM:SS')); %#ok<DATST,TNOW1>
                    catch
                    end
                end
            catch
                obj.debugFid = -1;
            end
        end

        function closeDebugLog(obj)
            if ~isempty(obj.debugFid) && obj.debugFid > 0
                try
                    fclose(obj.debugFid);
                catch
                end
            end
            obj.debugFid = -1;
        end

        function logEvent(obj, tag, msg)
            if ~obj.EnableDebugLog
                return;
            end
            if isempty(obj.debugFid) || obj.debugFid <= 0
                return;
            end
            try
                fprintf(obj.debugFid, '%.6f,%s,%s\n', ...
                    obj.timeNow(), char(tag), char(msg));
            catch
                % Si se rompe el handle, marcarlo como invalido y seguir.
                obj.debugFid = -1;
            end
        end

        % ---- Conexion ----

        function connectPhone(obj)
            obj.cleanupOwnPhone();

            if obj.CleanupBaseWorkspace
                obj.cleanupBaseWorkspaceHandles();
            end

            new_phone = [];
            try
                new_phone = mobiledev;
            catch ME
                if contains(lower(ME.message), 'already exists')
                    obj.logEvent("CONNECT_RETRY", ...
                        "singleton residual; limpiando y reintentando");
                    if obj.CleanupBaseWorkspace
                        obj.cleanupBaseWorkspaceHandles();
                    end
                    try
                        new_phone = mobiledev;
                    catch ME2
                        obj.handleConnectFailure(ME2, "");
                        return;
                    end
                else
                    obj.handleConnectFailure(ME, "");
                    return;
                end
            end

            try
                new_phone.AccelerationSensorEnabled = 1;
                new_phone.AngularVelocitySensorEnabled = 1;
                if obj.UseOrientation
                    new_phone.OrientationSensorEnabled = 1;
                end
                try
                    discardlogs(new_phone);
                catch
                end
                new_phone.Logging = 1;
            catch ME
                try
                    delete(new_phone);
                catch
                end
                obj.handleConnectFailure(ME, "config sensores: ");
                return;
            end

            obj.phone = new_phone;
            obj.isConnected = true;

            t_now = obj.timeNow();
            obj.lastPurgeTime = t_now;
            obj.lastSampleTime = 0;
            obj.lastValueChangeTime = t_now;
            obj.lastReconnectTime = t_now;
            obj.lastJitterReportTime = t_now;

            % Reset del jitter tracker: que el primer cambio post-conexion
            % no se cuente como dt.
            obj.jitter_prevT = NaN;
            obj.jitter_dtMin = NaN;
            obj.jitter_dtMax = NaN;
            obj.jitter_dtSum = 0;
            obj.jitter_dtCount = 0;

            obj.prev_ax = NaN; obj.prev_ay = NaN; obj.prev_az = NaN;
            obj.prev_gx = NaN; obj.prev_gy = NaN; obj.prev_gz = NaN;
            obj.prev_yaw = NaN; obj.prev_pitch = NaN; obj.prev_roll = NaN;

            obj.logEvent("CONNECT", "mobiledev OK; sensores habilitados; Logging=1");
        end

        function handleConnectFailure(obj, ME, ctx)
            obj.isConnected = false;
            obj.phone = [];
            obj.logEvent("CONNECT_FAIL", [char(ctx) ME.message]);
            if obj.WarnIfNoData
                warning("MobileMATLABReader:Connect", ...
                    "No se pudo conectar a MATLAB Mobile: %s%s", ctx, ME.message);
            end
        end

        function cleanupOwnPhone(obj)
            if ~isempty(obj.phone)
                try
                    obj.phone.Logging = 0;
                catch
                end
                try
                    delete(obj.phone);
                catch
                end
                obj.phone = [];
            end
        end

        function cleanupBaseWorkspaceHandles(obj)
            try
                names = evalin('base', "who('-class','mobiledev')");
            catch
                names = {};
            end
            if isempty(names)
                return;
            end

            for k = 1:numel(names)
                nm = names{k};
                try
                    evalin('base', sprintf('try, %s.Logging = 0; catch, end', nm));
                catch
                end
                try
                    evalin('base', sprintf('try, delete(%s); catch, end', nm));
                catch
                end
                try
                    evalin('base', sprintf('clear %s', nm));
                catch
                end
                obj.logEvent("CLEANUP_BASE", ...
                    sprintf("se libero handle '%s' del base workspace", nm));
            end
        end

        function tryReconnect(obj, t)
            if (t - obj.lastReconnectTime) < obj.ReconnectPeriod
                return;
            end
            obj.lastReconnectTime = t;
            obj.connectPhone();
            if ~obj.isConnected
                obj.logEvent("RECONNECT_FAIL", "sin conexion a MATLAB Mobile");
                obj.warnThrottled("MobileMATLABReader:Reconnect", ...
                    "Sin conexion a MATLAB Mobile. Sigo con la ultima muestra valida.", t);
            end
        end

        % ---- Lectura instantanea ----

        function readInstant(obj, t_now)
            got_valid_data = false;
            value_changed = false;

            a = obj.phone.Acceleration;
            if isnumeric(a) && numel(a) == 3 && all(isfinite(a))
                ax = double(a(1)); ay = double(a(2)); az = double(a(3));
                if ~(ax == obj.prev_ax && ay == obj.prev_ay && az == obj.prev_az)
                    value_changed = true;
                    obj.prev_ax = ax; obj.prev_ay = ay; obj.prev_az = az;
                end
                obj.last_ax = ax;
                obj.last_ay = ay;
                obj.last_az = az;
                got_valid_data = true;
            end

            g = obj.phone.AngularVelocity;
            if isnumeric(g) && numel(g) == 3 && all(isfinite(g))
                gx = double(g(1)); gy = double(g(2)); gz = double(g(3));
                if ~(gx == obj.prev_gx && gy == obj.prev_gy && gz == obj.prev_gz)
                    value_changed = true;
                    obj.prev_gx = gx; obj.prev_gy = gy; obj.prev_gz = gz;
                end
                obj.last_gx = gx;
                obj.last_gy = gy;
                obj.last_gz = gz;
                got_valid_data = true;
            end

            if obj.UseOrientation
                o = obj.phone.Orientation;
                if isnumeric(o) && numel(o) == 3 && all(isfinite(o))
                    yw = double(o(1)); pt = double(o(2)); rl = double(o(3));
                    if ~(yw == obj.prev_yaw && pt == obj.prev_pitch && rl == obj.prev_roll)
                        value_changed = true;
                        obj.prev_yaw = yw; obj.prev_pitch = pt; obj.prev_roll = rl;
                    end
                    obj.last_yaw = yw;
                    obj.last_pitch = pt;
                    obj.last_roll = rl;
                    got_valid_data = true;
                end
            end

            if got_valid_data
                obj.lastSampleTime = t_now;

                if value_changed
                    obj.lastValueChangeTime = t_now;

                    % Jitter: dt entre cambios consecutivos
                    if ~isnan(obj.jitter_prevT)
                        dt = t_now - obj.jitter_prevT;
                        if dt > 0
                            if isnan(obj.jitter_dtMin) || dt < obj.jitter_dtMin
                                obj.jitter_dtMin = dt;
                            end
                            if isnan(obj.jitter_dtMax) || dt > obj.jitter_dtMax
                                obj.jitter_dtMax = dt;
                            end
                            obj.jitter_dtSum = obj.jitter_dtSum + dt;
                            obj.jitter_dtCount = obj.jitter_dtCount + 1;
                        end
                    end
                    obj.jitter_prevT = t_now;
                end

                if (t_now - obj.lastDebugSampleTime) >= obj.DebugSamplePeriod
                    obj.lastDebugSampleTime = t_now;
                    obj.logEvent("SAMPLE", sprintf( ...
                        "a=[%.4g %.4g %.4g], g=[%.4g %.4g %.4g], ypr=[%.4g %.4g %.4g], changed=%d", ...
                        obj.last_ax, obj.last_ay, obj.last_az, ...
                        obj.last_gx, obj.last_gy, obj.last_gz, ...
                        obj.last_yaw, obj.last_pitch, obj.last_roll, ...
                        value_changed));
                end
            end
        end

        % ---- Reporte de jitter / rate efectivo ----

        function emitJitterReport(obj, t_now)
            if obj.jitter_dtCount > 0
                avg_dt = obj.jitter_dtSum / obj.jitter_dtCount;
                if avg_dt > 0
                    eff_rate = 1 / avg_dt;
                else
                    eff_rate = NaN;
                end
                obj.logEvent("STATS", sprintf( ...
                    "fresh=%d eff_rate=%.2fHz dt_min=%.2fms dt_avg=%.2fms dt_max=%.2fms target=%.2fHz", ...
                    obj.jitter_dtCount, eff_rate, ...
                    obj.jitter_dtMin * 1000, avg_dt * 1000, obj.jitter_dtMax * 1000, ...
                    obj.Rate));
            else
                obj.logEvent("STATS", sprintf( ...
                    "fresh=0 (sin cambios de valor en %.1fs) target=%.2fHz", ...
                    t_now - obj.lastJitterReportTime, obj.Rate));
            end

            % Reset de ventana
            obj.jitter_dtMin = NaN;
            obj.jitter_dtMax = NaN;
            obj.jitter_dtSum = 0;
            obj.jitter_dtCount = 0;
            obj.lastJitterReportTime = t_now;
        end

        % ---- Utilidades ----

        function warnThrottled(obj, id, msg, t)
            if obj.WarnIfNoData && (t - obj.lastWarnTime > 5)
                warning(id, "%s", msg);
                obj.lastWarnTime = t;
            end
        end

        function t = timeNow(obj)
            if isempty(obj.startTime)
                t = 0;
            else
                t = toc(obj.startTime);
            end
        end
    end
end
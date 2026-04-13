classdef PendulumFusion < matlab.System
% PendulumFusion  Fusión de sensores IMU para estimación de orientación.
%
%   Envuelve ahrsfilter / imufilter (Navigation Toolbox) en un System Object
%   reutilizable como bloque MATLAB System en Simulink o en scripts.
%
%   ENTRADAS  (vectores 1x3)
%     accel :  aceleración          [ g  ]   [ax  ay  az ]
%     gyro  :  velocidad angular    [deg/s]  [gx  gy  gz ]
%     mag   :  campo magnético      [ µT ]   [mx  my  mz ]
%                (solo para FilterType = 'AHRS')
%
%   SALIDAS
%     roll  :  rotación sobre X  [grados]
%     pitch :  rotación sobre Y  [grados]
%     yaw   :  rotación sobre Z  [grados]
%     q     :  cuaternión [w x y z]  (1x4)
%
%   EJEMPLO (script)
%     fus = PendulumFusion('SampleRate',200,'FilterType','AHRS');
%     [roll,pitch,yaw,q] = fus([0 0 1],[0 0 0],[20 -30 40]);
%
%   EJEMPLO (Simulink)
%     Agrega un bloque "MATLAB System" y selecciona PendulumFusion.
%     Conecta: accel(1x3) | gyro(1x3) | mag(1x3) → roll | pitch | yaw | q(1x4)

    % ------------------------------------------------------------------ %
    properties (Nontunable)
        SampleRate          (1,1) double {mustBePositive}  = 200
        FilterType          (1,:) char  {mustBeMember(FilterType, ...
                                {'AHRS','IMU','Complementary'})}  = 'AHRS'
        % Mahony / Madgwick tuning (acceso a AccelerometerGain en ahrsfilter)
        AccelerometerNoise  (1,1) double {mustBePositive}  = 0.0012
        GyroscopeDriftNoise (1,1) double {mustBePositive}  = 3.0517e-06
    end

    % ------------------------------------------------------------------ %
    properties (Access = private)
        filt_obj
        k_accel   % g → m/s²     (9.80665)
        k_gyro    % deg/s → rad/s (pi/180)
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)

        % ---- setup --------------------------------------------------- %
        function setupImpl(obj)
            obj.k_accel = 9.80665;
            obj.k_gyro  = pi / 180.0;

            switch obj.FilterType
                case 'AHRS'
                    obj.filt_obj = ahrsfilter( ...
                        'SampleRate',          obj.SampleRate, ...
                        'AccelerometerNoise',  obj.AccelerometerNoise, ...
                        'GyroscopeDriftNoise', obj.GyroscopeDriftNoise);

                case 'IMU'
                    obj.filt_obj = imufilter( ...
                        'SampleRate',          obj.SampleRate, ...
                        'AccelerometerNoise',  obj.AccelerometerNoise, ...
                        'GyroscopeDriftNoise', obj.GyroscopeDriftNoise);

                case 'Complementary'
                    obj.filt_obj = complementaryFilter( ...
                        'SampleRate',          obj.SampleRate, ...
                        'HasMagnetometer',     strcmp(obj.FilterType,'AHRS'));
            end
        end

        % ---- step ---------------------------------------------------- %
        function [roll, pitch, yaw, q_out] = stepImpl(obj, accel, gyro, mag)
            accel_ms2 = double(accel) * obj.k_accel;   % g  → m/s²
            gyro_rads = double(gyro)  * obj.k_gyro;    % deg/s → rad/s

            switch obj.FilterType
                case 'AHRS'
                    q_k = obj.filt_obj(accel_ms2, gyro_rads, double(mag));
                case 'IMU'
                    q_k = obj.filt_obj(accel_ms2, gyro_rads);
                case 'Complementary'
                    if nargin >= 4
                        q_k = obj.filt_obj(accel_ms2, gyro_rads, double(mag));
                    else
                        q_k = obj.filt_obj(accel_ms2, gyro_rads);
                    end
            end

            % quaternion → Euler ZYX en grados (convención 'frame')
            euler = eulerd(q_k, 'ZYX', 'frame');   % [yaw, pitch, roll]
            yaw   = euler(1);
            pitch = euler(2);
            roll  = euler(3);
            q_out = compact(q_k);           % [w x y z]  1x4
        end

        % ---- reset --------------------------------------------------- %
        function resetImpl(obj)
            if ~isempty(obj.filt_obj)
                reset(obj.filt_obj);
            end
        end

        % ---- port sizing (Simulink) ----------------------------------- %
        function n = getNumInputsImpl(obj)
            if strcmp(obj.FilterType, 'AHRS')
                n = 3;      % accel, gyro, mag
            else
                n = 2;      % accel, gyro
            end
        end

        function n = getNumOutputsImpl(~)
            n = 4;          % roll, pitch, yaw, q
        end

        function [s1, s2, s3, s4] = getOutputSizeImpl(~)
            s1 = [1 1]; s2 = [1 1]; s3 = [1 1]; s4 = [1 4];
        end

        function [d1, d2, d3, d4] = getOutputDataTypeImpl(~)
            d1 = 'double'; d2 = 'double'; d3 = 'double'; d4 = 'double';
        end

        function [c1, c2, c3, c4] = isOutputComplexImpl(~)
            c1 = false; c2 = false; c3 = false; c4 = false;
        end

        function [f1, f2, f3, f4] = isOutputFixedSizeImpl(~)
            f1 = true; f2 = true; f3 = true; f4 = true;
        end

    end % methods protected
end % classdef

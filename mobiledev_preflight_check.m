%% mobiledev_preflight_check
% Prueba MATLAB Mobile fuera de Simulink para saber si falla el celular,
% mobiledev o el modelo.

clc; clear;

duration_s = 30;
sample_period_s = 0.2;  % 5 Hz de diagnostico, suficiente para verificar vida
log_file = fullfile(pwd, 'mobiledev_preflight_check.log');

fid = fopen(log_file, 'w');
fprintf(fid, 't,event,ax,ay,az,gx,gy,gz,yaw,pitch,roll,message\n');

fprintf('Probando mobiledev durante %.1f s...\n', duration_s);
fprintf('Log: %s\n\n', log_file);

try
    phone = mobiledev;
    phone.AccelerationSensorEnabled = 1;
    phone.AngularVelocitySensorEnabled = 1;
    phone.OrientationSensorEnabled = 1;
    discardlogs(phone);
    phone.Logging = 1;
    fprintf(fid, '0,CONNECT,,,,,,,,,,mobiledev conectado\n');
catch ME
    fprintf(fid, '0,CONNECT_FAIL,,,,,,,,,,%s\n', clean_msg(ME.message));
    fclose(fid);
    error('No se pudo crear mobiledev: %s', ME.message);
end

t0 = tic;
last_a = [NaN NaN NaN];
last_g = [NaN NaN NaN];
new_accel_count = 0;
new_gyro_count = 0;

while toc(t0) < duration_s
    t = toc(t0);

    a = read_vec3(phone, 'Acceleration');
    g = read_vec3(phone, 'AngularVelocity');
    o = read_vec3(phone, 'Orientation');

    if all(isfinite(a)) && any(a ~= last_a)
        new_accel_count = new_accel_count + 1;
        last_a = a;
    end

    if all(isfinite(g)) && any(g ~= last_g)
        new_gyro_count = new_gyro_count + 1;
        last_g = g;
    end

    fprintf(fid, '%.6f,SAMPLE,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,\n', ...
        t, a(1), a(2), a(3), g(1), g(2), g(3), o(1), o(2), o(3));

    fprintf('t=%5.1f s | a=[%7.3f %7.3f %7.3f] | g=[%7.3f %7.3f %7.3f]\n', ...
        t, a(1), a(2), a(3), g(1), g(2), g(3));

    pause(sample_period_s);
end

try
    phone.Logging = 0;
catch
end

fprintf(fid, '%.6f,SUMMARY,,,,,,,,,,new_accel=%d new_gyro=%d\n', ...
    toc(t0), new_accel_count, new_gyro_count);
fclose(fid);

fprintf('\nResumen:\n');
fprintf('  Cambios de acelerometro detectados: %d\n', new_accel_count);
fprintf('  Cambios de giroscopio detectados:   %d\n', new_gyro_count);

if new_accel_count == 0 && new_gyro_count == 0
    fprintf('\nDiagnostico: MATLAB detecto mobiledev, pero no llegan muestras nuevas.\n');
    fprintf('Revisa MATLAB Mobile > Sensors > More > Sensor Access y deja la app abierta.\n');
elseif new_accel_count > 0 && new_gyro_count == 0
    fprintf('\nDiagnostico: acelerometro vivo, giroscopio sin datos.\n');
    fprintf('Revisa permiso/sensor de gyroscope en MATLAB Mobile.\n');
else
    fprintf('\nDiagnostico: mobiledev esta vivo fuera de Simulink.\n');
    fprintf('Si Simulink falla, revisar solver, Rate y bloques de guardado/scope.\n');
end

function v = read_vec3(phone, prop)
    try
        v = phone.(prop);
        if ~(isnumeric(v) && numel(v) == 3 && all(isfinite(v)))
            v = [NaN NaN NaN];
        else
            v = double(v(:).');
        end
    catch
        v = [NaN NaN NaN];
    end
end

function s = clean_msg(s)
    s = strrep(s, ',', ';');
    s = strrep(s, newline, ' ');
end


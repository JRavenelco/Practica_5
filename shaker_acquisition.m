%% shaker_acquisition.m — Excitación + adquisición simultánea
% Conecta el shaker LAC y el Pico W para hacer:
%   1. Excitación sinusoidal con el L12
%   2. Adquisición IMU del péndulo simultáneamente
%   3. Guardar datos y graficar
%
% Uso:
%   cd('C:\Users\jesus\Desktop\Practica_5')
%   shaker_acquisition

%% Parámetros de excitación
SHAKE_FREQ_HZ   = 1.0;    % Frecuencia de oscilación (Hz)
SHAKE_AMP_PCT   = 30;     % Amplitud (% del stroke)
DURATION_S      = 30;     % Duración de adquisición (s)
PICO_HOST       = '192.168.17.54';
PICO_PORT       = 4242;
IMU_RATE        = 200;    % Tasa de muestreo IMU (Hz)

%% Configurar Python (solo la primera vez)
pe = pyenv;
if pe.Status == "NotLoaded"
    fprintf('Python: %s\n', pe.Executable);
end

%% Conectar shaker
fprintf('Conectando shaker LAC...\n');
shaker = LACShaker('StrokeMM', 50, 'CenterPct', 50);
shaker.connect();

%% Conectar Pico W
fprintf('Conectando Pico W (%s:%d)...\n', PICO_HOST, PICO_PORT);
reader = PicoPendulumReader('Host', PICO_HOST, 'Port', PICO_PORT, ...
    'Rate', IMU_RATE, 'StartOnSetup', true);
setup(reader);

%% Pre-allocar datos
N_samples = DURATION_S * IMU_RATE;
data = zeros(N_samples, 10);  % [t, ax,ay,az, gx,gy,gz, mx,my,mz]
idx = 0;

%% Iniciar excitación (no-bloqueante) y adquisición
fprintf('Iniciando excitación: %.1f Hz, %d%% amplitud, %ds\n', ...
    SHAKE_FREQ_HZ, SHAKE_AMP_PCT, DURATION_S);
shaker.startSine(SHAKE_FREQ_HZ, SHAKE_AMP_PCT);

fprintf('Adquiriendo datos...\n');
t_start = tic;
while toc(t_start) < DURATION_S
    try
        [t, ax, ay, az, gx, gy, gz, mx, my, mz] = step(reader);
        idx = idx + 1;
        if idx <= N_samples
            data(idx, :) = [t, ax, ay, az, gx, gy, gz, mx, my, mz];
        end
    catch e
        fprintf('Error en lectura: %s\n', e.message);
    end
end

%% Parar
fprintf('Deteniendo...\n');
shaker.stop();
release(reader);

% Recortar al tamaño real
data = data(1:idx, :);
fprintf('Capturados %d muestras en %.1f s\n', idx, data(end,1)-data(1,1));

%% Guardar
filename = sprintf('shaker_data_%.1fHz_%dpct_%ds.csv', ...
    SHAKE_FREQ_HZ, SHAKE_AMP_PCT, DURATION_S);
headers = {'t_s','ax','ay','az','gx','gy','gz','mx','my','mz'};
T = array2table(data, 'VariableNames', headers);
writetable(T, filename);
fprintf('Datos guardados en: %s\n', filename);

%% Graficar
t_vec = data(:,1) - data(1,1);  % tiempo relativo

figure('Name', 'Shaker + IMU Acquisition', 'Position', [100 100 1000 700]);

subplot(3,1,1)
plot(t_vec, data(:,2), t_vec, data(:,3), t_vec, data(:,4));
legend('a_x','a_y','a_z');
ylabel('Aceleración (g)');
title(sprintf('Excitación sinusoidal: %.1f Hz, %d%% amplitud', ...
    SHAKE_FREQ_HZ, SHAKE_AMP_PCT));
grid on;

subplot(3,1,2)
plot(t_vec, data(:,5), t_vec, data(:,6), t_vec, data(:,7));
legend('\omega_x','\omega_y','\omega_z');
ylabel('Vel. angular (°/s)');
grid on;

subplot(3,1,3)
plot(t_vec, data(:,8), t_vec, data(:,9), t_vec, data(:,10));
legend('m_x','m_y','m_z');
ylabel('Campo mag. (µT)');
xlabel('Tiempo (s)');
grid on;

%% Desconectar shaker
shaker.disconnect();
fprintf('Listo!\n');

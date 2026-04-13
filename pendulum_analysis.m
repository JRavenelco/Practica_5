%% ====================================================================
%  PENDULUM ANALYSIS — IMU Fusion + Análisis Espectral
%  =====================================================================
%  Flujo:
%    1. Adquisición  — TCP live (Pico W) o CSV offline
%    2. Fusión AHRS  — ahrsfilter (Navigation Toolbox)
%    3. FFT          — espectro de magnitud por canal
%    4. Espectrograma — frecuencia vs. tiempo (STFT)
%    5. Envolvente   — transformada de Hilbert
%    6. Bode         — tfestimate ax→Roll
%    7. Armónicos    — findpeaks dominantes
%
%  Requisitos:  Navigation Toolbox, Signal Processing Toolbox
% =====================================================================

%% ---- 0. PARÁMETROS CONFIGURABLES -----------------------------------
PICO_IP   = '192.168.1.83';   % IP del Pico W en la red "Robot"
PICO_PORT = 4242;               % puerto TCP del firmware
Fs        = 200;                % Hz  (debe coincidir con RATE enviado)
N_SAMPLES = 2000;               % número de muestras a adquirir
USE_LIVE  = true;               % true=TCP Pico W  /  false=CSV offlinesu
CSV_FILE  = 'datos_pendulo.csv';% archivo a leer/escribir

% Parámetros del filtro (ahrsfilter)
ACCEL_NOISE   = 0.0012;        % varianza de ruido del acelerómetro
GYRO_DRIFT    = 3.0517e-06;    % varianza de drift del giróscopo
%% ---- 1. ADQUISICIÓN DE DATOS ----------------------------------------
if USE_LIVE
    fprintf('[1/7] Conectando a Pico W  %s:%d  (puede tardar ~5 s)...\n', ...
            PICO_IP, PICO_PORT);

    reader = PicoPendulumReader( ...
        'Host',         PICO_IP,   ...
        'Port',         PICO_PORT, ...
        'Rate',         Fs,        ...
        'StartOnSetup', true);
    setup(reader);

    t_raw  = zeros(N_SAMPLES, 1);
    accel  = zeros(N_SAMPLES, 3);   % [ax ay az]  g
    gyro   = zeros(N_SAMPLES, 3);   % [gx gy gz]  deg/s
    mag    = zeros(N_SAMPLES, 3);   % [mx my mz]  µT

    fprintf('[1/7] Adquiriendo %d muestras @ %d Hz ...\n', N_SAMPLES, Fs);

    for k = 1 : N_SAMPLES
        [t, ax, ay, az, gx, gy, gz, mx, my, mz] = step(reader);
        t_raw(k)   = t;
        accel(k,:) = [ax, ay, az];
        gyro(k,:)  = [gx, gy, gz];
        mag(k,:)   = [mx, my, mz];
    end
    release(reader);

    % Guardar para análisis offline
    header = {'t_s','ax_g','ay_g','az_g','gx_dps','gy_dps','gz_dps','mx_uT','my_uT','mz_uT'};
    T_save = array2table([t_raw, accel, gyro, mag], 'VariableNames', header);
    writetable(T_save, CSV_FILE);
    fprintf('[1/7] Datos guardados en  %s\n', CSV_FILE);

else
    fprintf('[1/7] Cargando datos de  %s ...\n', CSV_FILE);
    T_load = readtable(CSV_FILE);
    t_raw  = T_load{:,1};
    accel  = T_load{:,2:4};
    gyro   = T_load{:,5:7};
    mag    = T_load{:,8:10};
    N_SAMPLES = size(accel, 1);
    fprintf('[1/7] %d muestras cargadas.\n', N_SAMPLES);
end

% Tiempo normalizado en segundos
t_s = t_raw - t_raw(1);

%% ---- 2. FUSIÓN AHRS ------------------------------------------------
fprintf('[2/7] Aplicando ahrsfilter (Navigation Toolbox)...\n');

filt = ahrsfilter( ...
    'SampleRate',          Fs,           ...
    'AccelerometerNoise',  ACCEL_NOISE,  ...
    'GyroscopeDriftNoise', GYRO_DRIFT);

accel_ms2 = accel * 9.80665;        % g  → m/s²
gyro_rads = gyro  * (pi/180);       % deg/s → rad/s
% mag permanece en µT (ahrsfilter lo acepta directamente)

q_all     = zeros(N_SAMPLES, 4);
euler_all = zeros(N_SAMPLES, 3);    % [yaw pitch roll]

for k = 1 : N_SAMPLES
    q_k = filt(accel_ms2(k,:), gyro_rads(k,:), mag(k,:));
    q_all(k,:)     = compact(q_k);
    euler_all(k,:) = eulerd(q_k, 'ZYX', 'frame');
end

yaw_deg   = euler_all(:, 1);
pitch_deg = euler_all(:, 2);
roll_deg  = euler_all(:, 3);

% ---- Plot orientación ----
figure('Name','[AHRS] Orientación estimada','NumberTitle','off');
ax1 = subplot(3,1,1); plot(t_s, roll_deg,  'b');  ylabel('Roll (°)');
                       title('Orientación AHRS'); grid on;
ax2 = subplot(3,1,2); plot(t_s, pitch_deg, 'r');  ylabel('Pitch (°)'); grid on;
ax3 = subplot(3,1,3); plot(t_s, yaw_deg,   'g');  ylabel('Yaw (°)');
                       xlabel('Tiempo (s)'); grid on;
linkaxes([ax1 ax2 ax3], 'x');

%% ---- 3. FFT POR CANAL ----------------------------------------------
fprintf('[3/7] Calculando FFT por canal...\n');

ch_signals  = [accel, gyro, roll_deg, pitch_deg, yaw_deg];
ch_names    = {'ax (g)','ay (g)','az (g)', ...
               'gx (°/s)','gy (°/s)','gz (°/s)', ...
               'Roll (°)','Pitch (°)','Yaw (°)'};

freq_axis   = (0 : N_SAMPLES-1) * (Fs / N_SAMPLES);
half_idx    = 1 : floor(N_SAMPLES / 2);

figure('Name','[FFT] Espectro de Magnitud','NumberTitle','off');
for i = 1 : 9
    sig_c = ch_signals(:, i) - mean(ch_signals(:, i));  % remover DC
    S     = abs(fft(sig_c)) / N_SAMPLES;
    S(2:end-1) = 2 * S(2:end-1);       % single-sided (doblar amplitudes)

    subplot(3, 3, i);
    plot(freq_axis(half_idx), S(half_idx));
    xlabel('Hz');  ylabel('|X(f)|');
    title(ch_names{i});  grid on;
    xlim([0, Fs/2]);
end
sgtitle('FFT — Single-Sided Spectrum');

%% ---- 4. ESPECTROGRAMA (frecuencia × tiempo) -----------------------
fprintf('[4/7] Calculando espectrogramas...\n');

win_len   = min(128, floor(N_SAMPLES / 8));
win_len   = 2^floor(log2(win_len));     % potencia de 2
overlap   = floor(win_len / 2);

sg_data   = [accel(:,3), roll_deg, pitch_deg];
sg_names  = {'az','Roll','Pitch'};

figure('Name','[STFT] Espectrograma','NumberTitle','off');
for i = 1 : 3
    sig_c = sg_data(:,i) - mean(sg_data(:,i));
    subplot(1, 3, i);
    spectrogram(sig_c, hamming(win_len), overlap, win_len, Fs, 'yaxis');
    title(sg_names{i});
end
sgtitle('Espectrograma (STFT)');

%% ---- 5. ENVOLVENTE DE VIBRACIÓN (Hilbert) -------------------------
fprintf('[5/7] Calculando envolventes (Hilbert)...\n');

env_data  = accel;          % ax, ay, az
env_names = {'ax','ay','az'};

figure('Name','[Hilbert] Envolvente de Vibración','NumberTitle','off');
for i = 1 : 3
    sig_c = env_data(:,i) - mean(env_data(:,i));
    env   = abs(hilbert(sig_c));

    subplot(3, 1, i);
    plot(t_s, sig_c, 'Color',[0.6 0.6 1],   'DisplayName','Señal');
    hold on;
    plot(t_s, env,   'r', 'LineWidth',1.5,   'DisplayName','Envolvente');
    hold off;
    ylabel('g');  xlabel('Tiempo (s)');
    title(env_names{i});  legend;  grid on;
end
sgtitle('Envolvente de Vibración — Transformada de Hilbert');

%% ---- 6. ESTIMACIÓN DE FUNCIÓN DE TRANSFERENCIA (Bode) ------------
fprintf('[6/7] Estimando transferencia ax → Roll (tfestimate)...\n');

nfft   = min(512, 2^nextpow2(floor(N_SAMPLES / 4)));
x_in   = accel(:,1)  - mean(accel(:,1));   % excitación: ax
y_out  = roll_deg     - mean(roll_deg);     % respuesta:  Roll

[Txy, F_tf] = tfestimate(x_in, y_out, hamming(nfft), nfft/2, nfft, Fs);

figure('Name','[Bode] ax → Roll','NumberTitle','off');
subplot(2,1,1);
semilogx(F_tf, 20*log10(abs(Txy) + eps), 'b');
xlabel('Frecuencia (Hz)');  ylabel('Magnitud (dB)');
title('Bode — Magnitud');   grid on;  xlim([0.1, Fs/2]);

subplot(2,1,2);
semilogx(F_tf, angle(Txy) * (180/pi), 'r');
xlabel('Frecuencia (Hz)');  ylabel('Fase (°)');
title('Bode — Fase');       grid on;  xlim([0.1, Fs/2]);
sgtitle('Función de Transferencia:  ax  →  Roll  (tfestimate)');

%% ---- 7. ANÁLISIS DE ARMÓNICOS DOMINANTES -------------------------
fprintf('[7/7] Detectando frecuencias dominantes en Roll...\n');

sig_roll = roll_deg - mean(roll_deg);
S_roll   = abs(fft(sig_roll)) / N_SAMPLES;
S_roll(2:end-1) = 2 * S_roll(2:end-1);

S_half = S_roll(half_idx);
F_half = freq_axis(half_idx);

min_peak_height = 0.05 * max(S_half);
[pks, locs] = findpeaks(S_half, F_half, ...
                'MinPeakHeight',    min_peak_height, ...
                'MinPeakDistance',  0.5,             ... % 0.5 Hz separación mínima
                'NPeaks',           8);

fprintf('\n  %-10s  %-12s\n', 'f (Hz)', 'Amplitud (°)');
fprintf('  %-10s  %-12s\n', repmat('-',1,10), repmat('-',1,12));
for i = 1 : length(pks)
    fprintf('  %-10.3f  %-12.4f\n', locs(i), pks(i));
end

figure('Name','[Armónicos] Frecuencias Dominantes en Roll','NumberTitle','off');
plot(F_half, S_half, 'b');
hold on;
plot(locs, pks, 'rv', 'MarkerFaceColor','r', 'MarkerSize',9);
for i = 1 : length(pks)
    text(locs(i), pks(i) * 1.12, sprintf('%.2f Hz', locs(i)), ...
         'HorizontalAlignment','center', 'Color','r', 'FontSize',8);
end
hold off;
xlabel('Frecuencia (Hz)');  ylabel('Amplitud (°)');
title('Armónicos Dominantes — Espectro de Roll');
grid on;  xlim([0, Fs/2]);

fprintf('\n=== Análisis completado ===\n');

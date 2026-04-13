%% =====================================================================
%  CREAR MODELO SIMULINK — Adquisición WiFi + Fusión AHRS + Análisis
%  =====================================================================
%  Genera  pendulum_modelo.slx  con la siguiente arquitectura:
%
%   [PicoPendulumReader]   PicoPendulumReader (MATLAB System)
%          |  t, ax..mz (10 escalares)
%          v
%   [Mux 3x]  accel[1x3], gyro[1x3], mag[1x3]
%          |
%          v
%   [PendulumFusion]   AHRS → roll, pitch, yaw, q[1x4]
%          |
%          v
%   [Scope]  orientación en tiempo real
%   [To Workspace]  guarda en base workspace para post-proceso
%   [Spectrum Analyzer]  FFT en vivo (DSP System Toolbox)
%
%  Requisitos:  Navigation Toolbox, DSP System Toolbox, Simulink
% =====================================================================

%% -- Parámetros del modelo ------------------------------------------
MODEL_NAME  = 'pendulum_modelo';
PICO_IP     = '192.168.17.54';
PICO_PORT   = 4242;
Fs          = 200;      % Hz
T_STOP      = 30;       % segundos de simulación
DT          = 1 / Fs;   % paso fijo = 5 ms

%% -- Crear / reabrir modelo ----------------------------------------
if bdIsLoaded(MODEL_NAME)
    close_system(MODEL_NAME, 0);
end
new_system(MODEL_NAME);
open_system(MODEL_NAME);

% Configurar solver: paso fijo discreto
set_param(MODEL_NAME, ...
    'SolverType',       'Fixed-step', ...
    'Solver',           'FixedStepDiscrete', ...
    'FixedStep',        num2str(DT), ...
    'StopTime',         num2str(T_STOP), ...
    'SystemTargetFile', 'grt.tlc');      % generic real-time

% Habilitar zoom al añadir bloques
set_param(MODEL_NAME, 'ZoomFactor', 'FitSystem');

%% -- Posiciones base -----------------------------------------------
%  Layout horizontal izquierda→derecha
X0 = 50;   Y0 = 150;
DX = 220;  DY = 120;

%% == BLOQUE 1: PicoPendulumReader (MATLAB System) ==================
blk_reader = [MODEL_NAME '/PicoPendulumReader'];
add_block('simulink/User-Defined Functions/MATLAB System', blk_reader, ...
    'System',     'PicoPendulumReader', ...
    'Position',   [X0, Y0, X0+160, Y0+120]);
% Pasar propiedades al System Object
set_param(blk_reader, 'System', sprintf( ...
    'PicoPendulumReader(''Host'',''%s'',''Port'',%d,''Rate'',%d)', ...
    PICO_IP, PICO_PORT, Fs));

%% == BLOQUES 2-4: Mux accel / gyro / mag ===========================
X1 = X0 + DX;

blk_mux_acc = [MODEL_NAME '/Mux_accel'];
add_block('simulink/Signal Routing/Mux', blk_mux_acc, ...
    'Inputs',    '3', ...
    'Position',  [X1, Y0,        X1+30, Y0+90]);

blk_mux_gyr = [MODEL_NAME '/Mux_gyro'];
add_block('simulink/Signal Routing/Mux', blk_mux_gyr, ...
    'Inputs',    '3', ...
    'Position',  [X1, Y0+DY,     X1+30, Y0+DY+90]);

blk_mux_mag = [MODEL_NAME '/Mux_mag'];
add_block('simulink/Signal Routing/Mux', blk_mux_mag, ...
    'Inputs',    '3', ...
    'Position',  [X1, Y0+2*DY,   X1+30, Y0+2*DY+90]);

%% == BLOQUE 5: PendulumFusion (MATLAB System) ======================
X2 = X1 + DX;

blk_fusion = [MODEL_NAME '/PendulumFusion'];
add_block('simulink/User-Defined Functions/MATLAB System', blk_fusion, ...
    'System',    'PendulumFusion', ...
    'Position',  [X2, Y0+DY-30, X2+160, Y0+DY+120]);
set_param(blk_fusion, 'System', sprintf( ...
    'PendulumFusion(''SampleRate'',%d,''FilterType'',''AHRS'')', Fs));

%% == BLOQUE 6: Scope de orientación ================================
X3 = X2 + DX + 40;

blk_scope = [MODEL_NAME '/Scope_orientacion'];
add_block('simulink/Sinks/Scope', blk_scope, ...
    'NumInputPorts', '3', ...
    'Position',      [X3, Y0+DY-30, X3+80, Y0+DY+120]);
set_param(blk_scope, ...
    'TimeRange',  num2str(T_STOP));

%% == BLOQUES 7-9: To Workspace  (roll / pitch / yaw) ===============
X4 = X3;
for i = 1:3
    lbl   = {'roll','pitch','yaw'};
    blk_w = [MODEL_NAME '/ToWS_' lbl{i}];
    add_block('simulink/Sinks/To Workspace', blk_w, ...
        'VariableName', lbl{i}, ...
        'SaveFormat',   'Array', ...
        'Position', [X4, Y0+DY*(i-1)+250, X4+100, Y0+DY*(i-1)+280]);
end

% To Workspace para tiempo
blk_t = [MODEL_NAME '/ToWS_t'];
add_block('simulink/Sinks/To Workspace', blk_t, ...
    'VariableName', 't_sim', ...
    'SaveFormat',   'Array', ...
    'Position', [X4, Y0+3*DY+70, X4+100, Y0+3*DY+100]);

add_block('simulink/Sources/Clock', [MODEL_NAME '/Clock'], ...
    'Position', [X4-120, Y0+3*DY+70, X4-60, Y0+3*DY+100]);

%% == BLOQUE 10: Spectrum Analyzer (DSP System Toolbox) =============
blk_sa = [MODEL_NAME '/SpectrumAnalyzer'];
add_block('dsplib/Sinks/Spectrum Analyzer', blk_sa, ...
    'NumInputPorts',      '1', ...
    'SampleRate',         num2str(Fs), ...
    'PlotAsTwoSidedSpectrum', 'off', ...
    'Position', [X3, Y0+DY+200, X3+100, Y0+DY+260]);

%% == CONEXIONES ====================================================

% PicoPendulumReader salidas:
% 1=t, 2=ax, 3=ay, 4=az, 5=gx, 6=gy, 7=gz, 8=mx, 9=my, 10=mz

% -- accel mux
add_line(MODEL_NAME, 'PicoPendulumReader/2', 'Mux_accel/1', 'autorouting','on');
add_line(MODEL_NAME, 'PicoPendulumReader/3', 'Mux_accel/2', 'autorouting','on');
add_line(MODEL_NAME, 'PicoPendulumReader/4', 'Mux_accel/3', 'autorouting','on');

% -- gyro mux
add_line(MODEL_NAME, 'PicoPendulumReader/5', 'Mux_gyro/1', 'autorouting','on');
add_line(MODEL_NAME, 'PicoPendulumReader/6', 'Mux_gyro/2', 'autorouting','on');
add_line(MODEL_NAME, 'PicoPendulumReader/7', 'Mux_gyro/3', 'autorouting','on');

% -- mag mux
add_line(MODEL_NAME, 'PicoPendulumReader/8',  'Mux_mag/1', 'autorouting','on');
add_line(MODEL_NAME, 'PicoPendulumReader/9',  'Mux_mag/2', 'autorouting','on');
add_line(MODEL_NAME, 'PicoPendulumReader/10', 'Mux_mag/3', 'autorouting','on');

% -- mux → PendulumFusion
add_line(MODEL_NAME, 'Mux_accel/1', 'PendulumFusion/1', 'autorouting','on');
add_line(MODEL_NAME, 'Mux_gyro/1',  'PendulumFusion/2', 'autorouting','on');
add_line(MODEL_NAME, 'Mux_mag/1',   'PendulumFusion/3', 'autorouting','on');

% -- PendulumFusion → Scope (1=roll, 2=pitch, 3=yaw)
add_line(MODEL_NAME, 'PendulumFusion/1', 'Scope_orientacion/1', 'autorouting','on');
add_line(MODEL_NAME, 'PendulumFusion/2', 'Scope_orientacion/2', 'autorouting','on');
add_line(MODEL_NAME, 'PendulumFusion/3', 'Scope_orientacion/3', 'autorouting','on');

% -- PendulumFusion → To Workspace
add_line(MODEL_NAME, 'PendulumFusion/1', 'ToWS_roll/1',  'autorouting','on');
add_line(MODEL_NAME, 'PendulumFusion/2', 'ToWS_pitch/1', 'autorouting','on');
add_line(MODEL_NAME, 'PendulumFusion/3', 'ToWS_yaw/1',   'autorouting','on');

% -- PendulumFusion roll → Spectrum Analyzer
add_line(MODEL_NAME, 'PendulumFusion/1', 'SpectrumAnalyzer/1', 'autorouting','on');

% -- Clock → To Workspace t
add_line(MODEL_NAME, 'Clock/1', 'ToWS_t/1', 'autorouting','on');

%% == GUARDAR =======================================================
save_system(MODEL_NAME, [MODEL_NAME '.slx']);
fprintf('Modelo guardado: %s.slx\n', MODEL_NAME);

%% == ALINEAR DIAGRAMA ===============================================
Simulink.BlockDiagram.arrangeSystem(MODEL_NAME);
save_system(MODEL_NAME);

fprintf('\nModelo listo. Para simular:\n');
fprintf('  1. Asegúrate de que el Pico W está encendido y en la red ''Robot''\n');
fprintf('  2. Abre %s.slx y presiona Run\n', MODEL_NAME);
fprintf('  3. Después de la simulación, ejecuta pendulum_analysis.m\n\n');

%% test_shaker_matlab.m — Prueba del LAC Shaker desde MATLAB
% Requisitos:
%   - LAC board conectada por USB y alimentada
%   - Python configurado: pyenv('Version','C:\Users\jesus\Desktop\Practica_5\.venv\Scripts\python.exe')
%
% Ejecútalo desde la carpeta del proyecto:
%   cd('C:\Users\jesus\Desktop\Practica_5')
%   test_shaker_matlab

%% 1. Verificar Python
fprintf('=== Verificando Python ===\n');
pe = pyenv;
fprintf('  Python: %s\n', pe.Executable);
fprintf('  Version: %s\n', pe.Version);
if pe.Status == "NotLoaded"
    fprintf('  Estado: No cargado (se cargará al primer uso)\n');
else
    fprintf('  Estado: %s\n', pe.Status);
end

%% 2. Conectar al shaker
fprintf('\n=== Conectando al LAC ===\n');
shaker = LACShaker('StrokeMM', 50, 'CenterPct', 50);
shaker.connect();

%% 3. Leer posición actual
pos = shaker.feedback();
fprintf('  Posición actual: %.1f%%\n', pos);

%% 4. Mover a posiciones estáticas
fprintf('\n=== Test: posiciones estáticas ===\n');

fprintf('  Moviendo a 20%%...\n');
shaker.move(20);
pause(2);
fprintf('  Posición: %.1f%%\n', shaker.feedback());

fprintf('  Moviendo a 80%%...\n');
shaker.move(80);
pause(2);
fprintf('  Posición: %.1f%%\n', shaker.feedback());

fprintf('  Centrando (50%%)...\n');
shaker.center();
pause(2);
fprintf('  Posición: %.1f%%\n', shaker.feedback());

%% 5. Oscilación sinusoidal (bloqueante, 5 segundos)
fprintf('\n=== Test: oscilación sinusoidal (1 Hz, 40%%, 5s) ===\n');
shaker.sine(1.0, 40, 5);

%% 6. Oscilación no-bloqueante + lectura de posición
fprintf('\n=== Test: oscilación no-bloqueante (0.5 Hz, 30%%) ===\n');
shaker.startSine(0.5, 30);

N = 50;
t_log = zeros(N, 1);
pos_log = zeros(N, 1);
t0 = tic;
for k = 1:N
    t_log(k) = toc(t0);
    pos_log(k) = shaker.feedback();
    pause(0.1);
end

shaker.stop();
pause(1);

% Graficar
figure('Name', 'LAC Shaker Test');
plot(t_log, pos_log, 'b.-');
xlabel('Tiempo (s)');
ylabel('Posición (%)');
title('Lectura de posición durante oscilación');
grid on;
ylim([0 100]);

%% 7. Desconectar
fprintf('\n=== Desconectando ===\n');
shaker.disconnect();
fprintf('Test completo!\n');

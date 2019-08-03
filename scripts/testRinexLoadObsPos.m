close all
clear
clc
addpath(genpath('../src'))

jab1file = '../data/JAB1080M.19o';

param = OBSRNX.getDefaults();
param.filtergnss = 'GE';

% First time run (load from RINEX)
jab1 = OBSRNX(jab1file);
jab1.saveToMAT();

% Load from MAT
%jab1 = OBSRNX.loadFromMAT('../data\JAB1080M.mat');


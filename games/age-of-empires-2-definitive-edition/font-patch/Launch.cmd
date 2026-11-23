@echo off
rem Steam launch option:  "<path>\Launch.cmd" %command%
rem Re-applies the font if needed, then starts the game whatever happened.
title AoE2 DE font check
call "%~dp0_run.cmd" apply
%*

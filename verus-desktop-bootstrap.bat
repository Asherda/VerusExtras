@ECHO OFF
SET PROCESS_NAME=Verus Desktop Bootstrap
TASKLIST /V /NH /FI "imagename eq cmd.exe"| FIND /I /C "%PROCESS_NAME%" > Nul
IF %errorlevel%==0 exit 1
TITLE %PROCESS_NAME%

SETLOCAL EnableDelayedExpansion

SET BOOTSTRAP_URL=https://bootstrap.veruscoin.io
SET VERUS_DESKTOP_VERSION=0.6.4-beta-1
SET VERUS_DESKTOP_URL=https://github.com/VerusCoin/Verus-Desktop/releases/download/v!VERUS_DESKTOP_VERSION!
SET "VRSC_DATA_DIR=%APPDATA%\Komodo\VRSC"

SET ZPARAMS=(sprout-proving.key sprout-verifying.key sapling-spend.params sapling-output.params sprout-groth16.params)
SET sprout-proving.key=8bc20a7f013b2b58970cddd2e7ea028975c88ae7ceb9259a5344a16bc2c0eef7
SET sprout-verifying.key=4bd498dae0aacfd8e98dc306338d017d9c08dd0918ead18172bd0aec2fc5df82
SET sapling-spend.params=8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13
SET sapling-output.params=2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4
SET sprout-groth16.params=b685d700c60328498fbde589c8c7c484c722b788b265b72af448a5bf0ee55b50

SET "ZPARAMS_DIR=%APPDATA%\ZcashParams"
SET ZPARAMS_URL=https://z.cash/downloads

CALL :MAIN
PAUSE
EXIT 0

:MAIN
cd !Temp!
SET "DOWNLOAD_CMD="
FOR %%x IN (CURL.EXE BITSADMIN.EXE) DO IF NOT [%%~$PATH:x]==[] IF NOT DEFINED DOWNLOAD_CMD SET "DOWNLOAD_CMD=FETCH_%%x"
IF NOT EXIST "!ZPARAMS_DIR!" (
	MD "!ZPARAMS_DIR!"
	(
	ECHO This directory stores common Zcash zkSNARK parameters. Note that it is
	ECHO distinct from the daemon's -datadir argument because the parameters are
	ECHO large and may be shared across multiple distinct -datadir's such as when
	ECHO setting up test networks.
	)>"!ZPARAMS_DIR!\README.txt"
)
CALL :FETCH_PARAMS
CALL :FETCH_BOOTSTRAP
CALL :FETCH_VRSC_DESKTOP
GOTO :EOF

:FETCH_VRSC_DESKTOP
ECHO Downloading Verus Desktop
CALL :!DOWNLOAD_CMD! "Verus-Desktop-Windows-v%VERUS_DESKTOP_VERSION%.zip"  "%VERUS_DESKTOP_URL%"
tar -xf "!Temp!\Verus-Desktop-Windows-v%VERUS_DESKTOP_VERSION%.zip" --directory "!Temp!"
SET "filehash="
CALL :GET_SHA256SUM "!Temp!\Verus-Desktop-Windows-v!VERUS_DESKTOP_VERSION!.exe" filehash
findstr /m "!filehash!" "!Temp!\Verus-Desktop-Windows-v%VERUS_DESKTOP_VERSION%.exe.signature.txt" >Nul
IF %errorlevel% equ 0 (
    ECHO Opening Verus Desktop Installer
    start "" "!Temp!\Verus-Desktop-Windows-v%VERUS_DESKTOP_VERSION%.exe"
) ELSE (
    ECHO Failed to verify Verus Desktop installer checksum
)
GOTO :EOF

:FETCH_BITSADMIN.EXE
SET "filename=%~1"
SET "URL=%~2"
CALL bitsadmin /transfer "Downloading %filename%" /priority FOREGROUND /download "%URL%/%filename%" "%Temp%\%filename%"
GOTO :EOF

:FETCH_CURL.EXE
SET "filename=%~1"
SET "URL=%~2"
curl -# -L -C - "%URL%/%filename%" -o "%Temp%/%filename%"
GOTO :EOF

:FETCH_PARAMS
FOR %%F IN %ZPARAMS% DO (
 	IF NOT EXIST "!ZPARAMS_DIR!\%%F"  (
        ECHO %%F does not exist, downloading
            CALL :!DOWNLOAD_CMD! "%%F" "!ZPARAMS_URL!"
            SET "filehash="
            CALL :GET_SHA256SUM "!Temp!\%%F" filehash
            IF NOT "!filehash!"=="!%%F!" (
        		ECHO Failed to verify parameter checksums!
			    DEL "!Temp!\%%F"
        		EXIT 1
        	) ELSE (
			MOVE "!Temp!\%%F" "!ZPARAMS_DIR!" >Nul
		)
    )
)
GOTO :EOF

:GET_SHA256SUM
SET "file=!%~1!"
SET "sha256sum="
FOR /f "skip=1 tokens=* delims=" %%# IN ('certutil -hashfile !file! SHA256') DO (
    IF NOT DEFINED sha256sum (
        FOR %%Z IN (%%#) DO SET "sha256sum=!sha256sum!%%Z"
    )
)
SET "%~2=!sha256sum!"
GOTO :EOF

:FETCH_BOOTSTRAP
    SET "USE_BOOTSTRAP=1"
    SET i=0
    IF NOT EXIST "!VRSC_DATA_DIR!" (
        ECHO No VRSC data directory found, creating directory.
        MD "!VRSC_DATA_DIR!"
    )
    FOR %%F IN (fee_estimates.dat, komodostate, komodostate.ind, peers.dat, db.log, debug.log, signedmasks) DO (
        IF  EXIST "!VRSC_DATA_DIR!\%%F" (
            ECHO Found "!VRSC_DATA_DIR!\%%F"
            SET USE_BOOTSTRAP=0
        )
    )
    FOR /D %%D IN (blocks, chainstate, database, notarisations) DO (
        IF EXIST "!VRSC_DATA_DIR!\%%D" (
            ECHO Found "!VRSC_DATA_DIR!\%%D"
            SET USE_BOOTSTRAP=0
        )
    )
    IF /I "!USE_BOOTSTRAP!" EQU "1" (
     ECHO Fetching VRSC bootstrap
        CALL :!DOWNLOAD_CMD! VRSC-bootstrap.tar.gz  !BOOTSTRAP_URL!
        CALL :!DOWNLOAD_CMD! VRSC-bootstrap.tar.gz.verusid !BOOTSTRAP_URL!
        SET "filehash="
        CALL :GET_SHA256SUM "!Temp!\VRSC-bootstrap.tar.gz" filehash
        findstr /m "!filehash!" "!Temp!\VRSC-bootstrap.tar.gz.verusid" >Nul
        IF !errorlevel! equ 0 (
            ECHO Checksum verified!
            ECHO Extracting Verus blockchain bootstrap
            tar -xf "!Temp!\VRSC-bootstrap.tar.gz" --directory "!VRSC_DATA_DIR!"
        ) ELSE (
	        ECHO "!filehash!"
            ECHO Failed to verify bootstrap checksum
          )
            del "!Temp!\VRSC-bootstrap.tar.gz"
            del "!Temp!\VRSC-bootstrap.tar.gz.verusid"
     )
GOTO :EOF

ENDLOCAL
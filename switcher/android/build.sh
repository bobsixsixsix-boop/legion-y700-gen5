#!/bin/bash
# Build the Y700 Switcher APK without Gradle: aapt2 -> javac -> d8 -> zipalign -> apksigner.
set -e
cd "$(dirname "$0")"
T=$(cd ../../tools && pwd)
JAVA_HOME=$(ls -d "$T"/jdk-21*); export JAVA_HOME
BT=$T/android-sdk/build-tools/36.1.0
JAR=$T/android-sdk/platforms/android-36/android.jar
w() { cygpath -w "$1"; }
rm -rf build; mkdir -p build/classes build/gen build/dex
"$BT/aapt2.exe" compile --dir res -o build/res.zip
"$BT/aapt2.exe" link -o build/unaligned.apk -I "$(w "$JAR")" --manifest AndroidManifest.xml build/res.zip --java build/gen --min-sdk-version 30 --target-sdk-version 36
"$JAVA_HOME/bin/javac.exe" -encoding UTF-8 --release 17 -classpath "$(w "$JAR")" -d build/classes $(find src build/gen -name '*.java')
cmd //c "$(w "$BT/d8.bat")" --release --min-api 30 --lib "$(w "$JAR")" --output "$(w build/dex)" $(find build/classes -name '*.class' | while read f; do cygpath -w "$f"; done)
python - <<'PY'
import zipfile
z=zipfile.ZipFile('build/unaligned.apk','a'); z.write('build/dex/classes.dex','classes.dex'); z.close()
PY
"$BT/zipalign.exe" -p -f 4 build/unaligned.apk build/aligned.apk
# Signing key: keystore.jks + keystore.pass (one line, the store and key password) live next to this
# script and are NOT in git (.gitignore). Keep a copy of both somewhere safe: an APK signed with a new
# key cannot update the installed one. A missing keystore is generated once with the password from the file.
KS=keystore.jks
[ -f keystore.pass ] || { echo "keystore.pass missing (one line: the keystore password)"; exit 1; }
PW=$(head -1 keystore.pass | tr -d '
')
[ -f $KS ] || "$JAVA_HOME/bin/keytool.exe" -genkeypair -keystore $KS -storepass "$PW" -keypass "$PW" -alias y700 -keyalg RSA -keysize 3072 -validity 36500 -dname "CN=Y700 Switcher"
cmd //c "$(w "$BT/apksigner.bat")" sign --ks $KS --ks-pass file:keystore.pass --key-pass file:keystore.pass --out y700-switcher.apk build/aligned.apk
cmd //c "$(w "$BT/apksigner.bat")" verify --print-certs y700-switcher.apk | head -3
ls -la y700-switcher.apk

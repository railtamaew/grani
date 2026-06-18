# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Uncomment this to preserve the line number information for
# debugging stack traces.
#-keepattributes SourceFile,LineNumberTable

# If you keep the line number information, uncomment this to
# hide the original source file name.
#-renamesourcefileattribute SourceFile

# Flutter specific rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# VPN specific rules
-keep class com.granivpn.mobile.** { *; }

# libXray (libXray.aar) rules - сохраняем все классы
-keep class libXray.** { *; }
-keep interface libXray.** { *; }
-keep class com.github.xtls.libxray.** { *; }
-keep interface com.github.xtls.libxray.** { *; }
-keep class go.** { *; }
-keep interface go.** { *; }

# XRay config classes
-keep class com.granivpn.mobile.XrayConfig { *; }
-keep class com.granivpn.mobile.XrayConfigParser { *; }
-keep class com.granivpn.mobile.XrayCoreJni { *; }
-keep class com.granivpn.mobile.XrayNativeWrapper { *; }

# Сохраняем нативные методы libXray (JNI)
-keepclasseswithmembernames class libXray.** {
    native <methods>;
}
-keepclasseswithmembernames class com.github.xtls.libxray.** {
    native <methods>;
}

# Сохраняем нативные методы (JNI)
-keepclasseswithmembernames class * {
    native <methods>;
}

# Сохраняем нативные библиотеки (.so файлы) - КРИТИЧНО для XRay
# R8 автоматически сохраняет .so файлы, специальные правила не требуются

# Сохраняем классы, используемые через рефлексию
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# Сохраняем аннотации для правильной работы
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes Exceptions
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Сохраняем имена классов для логирования
-keepnames class * implements java.io.Serializable
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# Игнорируем отсутствующие классы Google Play Core (опциональные зависимости для deferred components)
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**










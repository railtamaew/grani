package com.granivpn.mobile

import android.util.Log

/**
 * JNI обертка для XRay-core библиотеки
 * 
 * Этот класс предоставляет интерфейс для вызова нативных функций XRay-core
 * через JNI (Java Native Interface).
 * 
 * Перед использованием необходимо убедиться, что библиотека libxray.so
 * добавлена в android/app/src/main/jniLibs/ для всех архитектур.
 */
object XrayCoreJni {
    private const val TAG = "XrayCoreJni"
    private var isLibraryLoaded = false
    
    init {
        loadLibrary()
    }
    
    /**
     * Загружает нативную библиотеку XRay-core
     */
    private fun loadLibrary() {
        if (isLibraryLoaded) {
            return
        }
        
        try {
            System.loadLibrary("xray")
            isLibraryLoaded = true
            Log.i(TAG, "XRay-core библиотека успешно загружена")
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "Не удалось загрузить библиотеку libxray.so: ${e.message}")
            Log.e(TAG, "Убедитесь, что библиотека добавлена в jniLibs/ для вашей архитектуры")
            isLibraryLoaded = false
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка загрузки библиотеки: ${e.message}", e)
            isLibraryLoaded = false
        }
    }
    
    /**
     * Проверяет, загружена ли библиотека
     */
    fun isLibraryAvailable(): Boolean {
        return isLibraryLoaded
    }
    
    /**
     * Запускает XRay-core с JSON конфигурацией
     * 
     * @param configJson JSON конфигурация XRay в виде строки
     * @return 0 при успехе, отрицательное значение при ошибке
     */
    external fun startXray(configJson: String): Int
    
    /**
     * Останавливает XRay-core
     * 
     * @return true при успехе, false при ошибке
     */
    external fun stopXray(): Boolean
    
    /**
     * Проверяет, запущен ли XRay-core
     * 
     * @return true если XRay запущен, false в противном случае
     */
    external fun isXrayRunning(): Boolean
    
    /**
     * Получает статистику XRay (опционально)
     * 
     * @return JSON строка со статистикой или null
     */
    external fun getXrayStats(): String?
    
    /**
     * Получает версию XRay-core
     * 
     * @return версия XRay-core или null
     */
    external fun getXrayVersion(): String?
}

/**
 * Проверяет доступность библиотеки перед использованием
 */
fun XrayCoreJni.checkLibrary(): Boolean {
    if (!XrayCoreJni.isLibraryAvailable()) {
        android.util.Log.w("XrayCoreJni", "Библиотека XRay-core не загружена. Проверьте наличие libxray.so в jniLibs/")
        return false
    }
    return true
}


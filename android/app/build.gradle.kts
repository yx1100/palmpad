plugins {
    id("com.android.application")
}

android {
    namespace = "app.mtm"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.yuxin1100.mtm"
        minSdk = 37
        targetSdk = 37
        versionCode = 1
        versionName = "0.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

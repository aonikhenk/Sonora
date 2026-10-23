import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Claves locales (no se suben a GitHub): local.properties
val local = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

android {
    namespace = "cl.zanetta.sonora"
    compileSdk = 35

    defaultConfig {
        applicationId = "cl.zanetta.sonora"
        minSdk = 26
        targetSdk = 35
        versionCode = 5
        versionName = "0.2.1"
        buildConfigField("String", "ONEDRIVE_CLIENT_ID", "\"${local.getProperty("onedrive.clientId", "")}\"")
    }

    signingConfigs {
        create("release") {
            val ks = local.getProperty("signing.storeFile")
            if (ks != null) {
                storeFile = rootProject.file(ks)
                storePassword = local.getProperty("signing.storePassword")
                keyAlias = local.getProperty("signing.keyAlias")
                keyPassword = local.getProperty("signing.keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (local.getProperty("signing.storeFile") != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.browser:browser:1.8.0")

    val media3 = "1.5.1"
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-session:$media3")
    implementation("androidx.media3:media3-datasource:$media3")
    implementation("androidx.media3:media3-database:$media3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-guava:1.9.0")
}

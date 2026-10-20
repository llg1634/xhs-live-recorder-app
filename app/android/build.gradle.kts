// 本机环境：dl.google.com 被代理拦截（返回 404），而部分 Flutter 插件
// （shared_preferences_android / webview_flutter_android 等）在自己的 build.gradle.kts 里
// 用 `buildscript { classpath("com.android.tools.build:gradle:8.13.1") }` 显式拉 AGP，
// 会绕过 settings 里的 pluginManagement 镜像。这里在根项目评估时就把阿里云镜像
// 注入到所有子项目的 buildscript 仓库最前面，保证子项目脚本求值时先命中镜像。
allprojects {
    buildscript.repositories.apply {
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
        maven("https://maven.aliyun.com/repository/public")
        maven("https://maven.aliyun.com/repository/gradle-plugin")
    }
    repositories {
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
        maven("https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

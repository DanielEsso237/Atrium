allprojects {
    repositories {
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
// Le meme NDK pour tous les modules, plugins compris (jni, utilise par la
// camera, prenait le 28.2 par defaut de Flutter, absent de nos postes et dont
// le telechargement echouait). Par reflexion : le script racine n'a pas les
// classes du plugin Android a la compilation.
subprojects {
    val fixerNdk = {
        extensions.findByName("android")?.let { android ->
            android.javaClass
                .getMethod("setNdkVersion", String::class.java)
                .invoke(android, "30.0.14904198")
        }
    }
    if (state.executed) fixerNdk() else afterEvaluate { fixerNdk() }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

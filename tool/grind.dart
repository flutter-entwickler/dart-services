// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library services.grind;

import 'dart:async';
import 'dart:convert' show JsonEncoder;
import 'dart:io';

import 'package:dart_services/src/project.dart';
import 'package:dart_services/src/project_creator.dart';
import 'package:dart_services/src/pub.dart';
import 'package:dart_services/src/sdk.dart';
import 'package:dart_services/src/utils.dart';
import 'package:grinder/grinder.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

Future<void> main(List<String> args) async {
  return grind(args);
}

@Task('Make sure SDKs are appropriately initialized')
@Depends(setupFlutterSdk)
void sdkInit() {}

@Task()
@Depends(buildProjectTemplates)
void analyze() async {
  await _run('dart', arguments: ['analyze']);
}

@Task()
@Depends(buildStorageArtifacts)
Future<void> test() => _run(Platform.executable, arguments: ['test']);

@DefaultTask()
@Depends(analyze, test)
void analyzeTest() {}

@Task()
@Depends(buildStorageArtifacts)
Future<void> serve() async {
  await _run(Platform.executable, arguments: [
    'bin/server_dev.dart',
    '--channel',
    _channel,
    '--port',
    '8082',
  ]);
}

@Task()
@Depends(buildStorageArtifacts)
Future<void> serveNullSafety() async {
  await _run(Platform.executable, arguments: [
    'bin/server_dev.dart',
    '--channel',
    _channel,
    '--port',
    '8084',
    '--null-safety',
  ]);
}

const _dartImageName = 'dart';
final _dockerVersionMatcher = RegExp('^FROM $_dartImageName:(.*)\$');
const _dockerFileNames = [
  'cloud_run_beta.Dockerfile',
  'cloud_run_dev.Dockerfile',
  'cloud_run_null_safety.Dockerfile',
  'cloud_run_old.Dockerfile',
  'cloud_run.Dockerfile',
];

/// Returns the Flutter channel provided in environment variables.
late final String _channel = () {
  final channel = Platform.environment['FLUTTER_CHANNEL'];
  if (channel == null) {
    throw StateError('Must provide FLUTTER_CHANNEL');
  }
  return channel;
}();

/// Returns the appropriate SDK for the given Flutter channel.
///
/// The Flutter SDK directory must be already created by [sdkInit].
Sdk _getSdk() => Sdk.create(_channel);

@Task('Update the docker and SDK versions')
void updateDockerVersion() {
  final platformVersion = Platform.version.split(' ').first;
  for (final _dockerFileName in _dockerFileNames) {
    final dockerFile = File(_dockerFileName);
    final dockerImageLines = dockerFile.readAsLinesSync().map((String s) {
      if (s.contains(_dockerVersionMatcher)) {
        return 'FROM $_dartImageName:$platformVersion';
      }
      return s;
    }).toList();
    dockerImageLines.add('');

    dockerFile.writeAsStringSync(dockerImageLines.join('\n'));
  }
}

final List<String> compilationArtifacts = [
  'dart_sdk.js',
  'flutter_web.js',
];

@Task('validate that we have the correct compilation artifacts available in '
    'google storage')
@Depends(sdkInit)
void validateStorageArtifacts() async {
  final sdk = _getSdk();
  print('validate-storage-artifacts version: ${sdk.version}');
  final version = sdk.versionFull;

  const nullUnsafeUrlBase =
      'https://storage.googleapis.com/compilation_artifacts/';
  const nullSafeUrlBase = 'https://storage.googleapis.com/nnbd_artifacts/';

  for (final urlBase in [nullUnsafeUrlBase, nullSafeUrlBase]) {
    for (final artifact in compilationArtifacts) {
      await _validateExists(Uri.parse('$urlBase$version/$artifact'));
    }
  }
}

Future<void> _validateExists(Uri url) async {
  log('checking $url...');

  final response = await http.head(url);
  if (response.statusCode != 200) {
    fail(
      'compilation artifact not found: $url '
      '(${response.statusCode} ${response.reasonPhrase})',
    );
  }
}

/// Builds the EIGHT project templates:
///
/// * the Dart project template (both null safe and pre-null safe),
/// * the Flutter project template (both null safe and pre-null safe),
/// * the Firebase project template (both null safe and pre-null safe).
/// * the deprecated Firebase project template (both null safe and pre-null
///   safe).
@Task('build the project templates')
@Depends(sdkInit)
void buildProjectTemplates() async {
  final templatesPath = path.join(Directory.current.path, 'project_templates');
  final templatesDirectory = Directory(templatesPath);
  final exists = await templatesDirectory.exists();
  if (exists) {
    await templatesDirectory.delete(recursive: true);
  }

  final sdk = _getSdk();
  for (final nullSafety in [true, false]) {
    final projectCreator = ProjectCreator(
      sdk,
      templatesPath,
      isNullSafe: nullSafety,
      dartLanguageVersion: readDartLanguageVersion(_channel),
      dependenciesFile: _pubDependenciesFile(channel: _channel),
      log: log,
    );
    await projectCreator.buildDartProjectTemplate();
    await projectCreator.buildFlutterProjectTemplate(
      firebaseStyle: FirebaseStyle.none,
    );
    await projectCreator.buildFlutterProjectTemplate(
      firebaseStyle: FirebaseStyle.deprecated,
    );
    await projectCreator.buildFlutterProjectTemplate(
      firebaseStyle: FirebaseStyle.flutterFire,
    );
  }
}

@Task('build the sdk compilation artifacts for upload to google storage')
@Depends(sdkInit, buildProjectTemplates)
void buildStorageArtifacts() async {
  final sdk = _getSdk();
  delete(getDir('artifacts'));
  final instructions = <String>[];

  for (final nullSafe in [false, true]) {
    // build and copy dart_sdk.js, flutter_web.js, and flutter_web.dill
    final temp = Directory.systemTemp.createTempSync('flutter_web_sample');

    try {
      instructions.add(await _buildStorageArtifacts(temp, sdk,
          nullSafety: nullSafe, channel: _channel));
    } finally {
      temp.deleteSync(recursive: true);
    }
  }
  log('\nFrom the dart-services project root dir, run:');
  for (final instruction in instructions) {
    log(instruction);
  }
}

Future<String> _buildStorageArtifacts(Directory dir, Sdk sdk,
    {required bool nullSafety, required String channel}) async {
  final dependenciesFile = _pubDependenciesFile(channel: channel);
  final pubspec = createPubspec(
    includeFlutterWeb: true,
    nullSafety: nullSafety,
    dartLanguageVersion: readDartLanguageVersion(_channel),
    dependencies: parsePubDependenciesFile(dependenciesFile: dependenciesFile),
  );
  joinFile(dir, ['pubspec.yaml']).writeAsStringSync(pubspec);

  await runFlutterPackagesGet(sdk.flutterToolPath, dir.path, log: log);

  // locate the artifacts
  final flutterPackages = ['flutter', 'flutter_test'];

  final flutterLibraries = <String>[];
  final packageLines = joinFile(dir, ['.packages']).readAsLinesSync();
  for (var line in packageLines) {
    line = line.trim();
    if (line.startsWith('#') || line.isEmpty) {
      continue;
    }
    final index = line.indexOf(':');
    if (index == -1) {
      continue;
    }
    final packageName = line.substring(0, index);
    final url = line.substring(index + 1);
    if (flutterPackages.contains(packageName)) {
      // This is a package we're interested in - add all the public libraries to
      // the list.
      final libPath = Uri.parse(url).toFilePath();
      for (final entity in getDir(libPath).listSync()) {
        if (entity is File && entity.path.endsWith('.dart')) {
          flutterLibraries.add('package:$packageName/${fileName(entity)}');
        }
      }
    }
  }

  // Make sure flutter-sdk/bin/cache/flutter_web_sdk/flutter_web_sdk/kernel/flutter_ddc_sdk.dill
  // is installed.
  await _run(
    sdk.flutterToolPath,
    arguments: ['precache', '--web'],
    workingDirectory: dir.path,
  );

  // Build the artifacts using DDC:
  // dart-sdk/bin/dartdevc -s kernel/flutter_ddc_sdk.dill
  //     --modules=amd package:flutter/animation.dart ...
  final compilerPath = path.join(sdk.dartSdkPath, 'bin', 'dartdevc');
  final dillPath = path.join(
    sdk.flutterWebSdkPath,
    nullSafety ? 'flutter_ddc_sdk_sound.dill' : 'flutter_ddc_sdk.dill',
  );

  final args = <String>[
    '-s',
    dillPath,
    if (nullSafety) ...[
      '--sound-null-safety',
      '--enable-experiment=non-nullable'
    ],
    '--modules=amd',
    '--source-map',
    '-o',
    'flutter_web.js',
    ...flutterLibraries
  ];

  await _run(
    compilerPath,
    arguments: args,
    workingDirectory: dir.path,
  );

  // Copy both to the project directory.
  final artifactsDir =
      getDir(path.join('artifacts', nullSafety ? 'null-safe' : 'null-unsafe'));
  artifactsDir.createSync(recursive: true);

  final sdkJsPath = path.join(
      sdk.flutterWebSdkPath,
      nullSafety
          ? 'amd-canvaskit-html-sound/dart_sdk.js'
          : 'amd-canvaskit-html/dart_sdk.js');

  copy(getFile(sdkJsPath), artifactsDir);
  copy(getFile('$sdkJsPath.map'), artifactsDir);
  copy(joinFile(dir, ['flutter_web.js']), artifactsDir);
  copy(joinFile(dir, ['flutter_web.js.map']), artifactsDir);
  copy(joinFile(dir, ['flutter_web.dill']), artifactsDir);

  // Emit some good Google Storage upload instructions.
  final version = sdk.versionFull;
  return ('  gsutil -h "Cache-Control: public, max-age=604800, immutable" cp -z js ${artifactsDir.path}/*.js*'
      ' gs://${nullSafety ? 'nnbd_artifacts' : 'compilation_artifacts'}/$version/');
}

@Task('Reinitialize the Flutter submodule.')
void setupFlutterSdk() async {
  print('setup-flutter-sdk channel: $_channel');

  // Download the SDK into ./flutter-sdks/
  final sdkManager = DownloadingSdkManager(_channel);
  print('Flutter version: ${sdkManager.flutterVersion}');
  final flutterSdkPath = await sdkManager.createFromConfigFile();

  // Set up the Flutter SDK the way dart-services needs it.

  final flutterBinFlutter = path.join(flutterSdkPath, 'bin', 'flutter');
  await _run(
    flutterBinFlutter,
    arguments: ['doctor'],
  );

  await _run(
    flutterBinFlutter,
    arguments: ['config', '--enable-web'],
  );

  await _run(
    flutterBinFlutter,
    arguments: [
      'precache',
      '--web',
      '--no-android',
      '--no-ios',
      '--no-linux',
      '--no-windows',
      '--no-macos',
      '--no-fuchsia',
    ],
  );
}

@Task()
void fuzz() {
  log('warning: fuzz testing is a noop, see #301');
}

@Task('Update generated files and run all checks prior to deployment')
@Depends(sdkInit, updateDockerVersion, generateProtos, analyze, test,
    validateStorageArtifacts)
void deploy() {
  log('Deploy via Google Cloud Console');
}

@Task()
@Depends(generateProtos, analyze, fuzz, buildStorageArtifacts)
void buildbot() {}

@Task('Generate Protobuf classes')
void generateProtos() async {
  try {
    await _run(
      'protoc',
      arguments: ['--dart_out=lib/src', 'protos/dart_services.proto'],
    );
  } catch (e) {
    print('Error running "protoc"; make sure the Protocol Buffer compiler is '
        'installed (see README.md)');
  }

  // reformat generated classes so travis dart format test doesn't fail
  await _run(
    'dart',
    arguments: ['format', '--fix', 'lib/src/protos'],
  );

  // And reformat again, for $REASONS
  await _run(
    'dart',
    arguments: ['format', '--fix', 'lib/src/protos'],
  );

  // generate common_server_proto.g.dart
  Pub.run('build_runner', arguments: ['build', '--delete-conflicting-outputs']);
}

Future<void> _run(
  String executable, {
  List<String> arguments = const [],
  String? workingDirectory,
  Map<String, String> environment = const {},
}) async {
  final process = await runWithLogging(executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      log: log);
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    fail('Unable to exec $executable, failed with code $exitCode');
  }
}

@Task('Update pubspec dependency versions')
@Depends(sdkInit)
void updatePubDependencies() async {
  final sdk = _getSdk();
  await _updateDependenciesFile(
      flutterToolPath: sdk.flutterToolPath, channel: _channel);
}

/// Updates the "dependencies file".
///
/// The new set of dependency packages, and their version numbers, is determined
/// by resolving versions of direct and indirect dependencies of a Flutter web
/// app with Firebase plugins in a scratch pub package.
///
/// See [_pubDependenciesFile] for the location of the dependencies files.
Future<void> _updateDependenciesFile({
  required String flutterToolPath,
  required String channel,
}) async {
  final tempDir = Directory.systemTemp.createTempSync('pubspec-scratch');
  final pubspec = createPubspec(
    includeFlutterWeb: true,
    nullSafety: true,
    dartLanguageVersion: readDartLanguageVersion(_channel),
    dependencies: {
      // pkg:lints and pkg:flutter_lints
      'lints': 'any',
      'flutter_lints': 'any',
      for (var package in firebasePackages) package: 'any',
      for (var package in supportedFlutterPackages) package: 'any',
      for (var package in supportedBasicDartPackages) package: 'any',
    },
  );
  joinFile(tempDir, ['pubspec.yaml']).writeAsStringSync(pubspec);
  await runFlutterPackagesGet(flutterToolPath, tempDir.path, log: log);
  final packageVersions = packageVersionsFromPubspecLock(tempDir.path);

  _pubDependenciesFile(channel: channel)
      .writeAsStringSync(_jsonEncoder.convert(packageVersions));
}

/// An encoder which indents nested elements by two spaces.
const JsonEncoder _jsonEncoder = JsonEncoder.withIndent('  ');

/// Returns the File containing the pub dependencies and their version numbers.
///
/// The file is at `tool/pub_dependencies_{channel}.json`, for the Flutter
/// channels: stable, beta, dev, old.
File _pubDependenciesFile({required String channel}) {
  final versionsFileName = 'pub_dependencies_$channel.json';
  return File(path.join(Directory.current.path, 'tool', versionsFileName));
}

/// 应用级常量。
///
/// 版本号与 commit 由构建期 `--dart-define` 注入 ——
/// 这样「关于」页显示的就是真实的构建来源，且不需要额外引入 package_info_plus。
class AppInfo {
  AppInfo._();

  static const String appName = '拟境';
  static const String appNameEn = 'nijing';
  static const String slogan = '世界书驱动的沉浸式情境推演';

  static const String repoOwner = 'makisekurse';
  static const String repoName = 'nijing';
  static const String repoUrl = 'https://github.com/makisekurse/nijing';
  static const String releasesUrl = '$repoUrl/releases';
  static const String latestReleaseApi =
      'https://api.github.com/repos/makisekurse/nijing/releases/latest';

  static const String developer = 'makisekurisu';
  static const String developerUrl = 'https://github.com/makisekurse';

  static const String version =
      String.fromEnvironment('APP_VERSION', defaultValue: '2.0.1-dev');
  static const String buildNumber =
      String.fromEnvironment('BUILD_NUMBER', defaultValue: '0');
  static const String gitSha =
      String.fromEnvironment('GIT_SHA', defaultValue: 'local');

  static String get versionLabel => '$version+$buildNumber';

  static String get shortSha =>
      gitSha.length > 7 ? gitSha.substring(0, 7) : gitSha;
}

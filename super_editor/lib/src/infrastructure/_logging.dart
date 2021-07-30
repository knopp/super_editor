import 'package:logging/logging.dart' as logging;

class LogNames {
  static const editor = 'editor';

  static const textField = 'textfield';
  static const androidTextField = 'textfield.android';
  static const iosTextField = 'textfield.ios';

  static const infrastructure = 'infrastructure';
  static const attributions = 'infrastructure.attributions';
}

final editorLog = logging.Logger(LogNames.editor);

final textFieldLog = logging.Logger(LogNames.textField);
final androidTextFieldLog = logging.Logger(LogNames.androidTextField);
final iosTextFieldLog = logging.Logger(LogNames.iosTextField);

final infrastructureLog = logging.Logger(LogNames.infrastructure);
final attributionsLog = logging.Logger(LogNames.attributions);

void initAllLogs(logging.Level level) {
  initLoggers(level, [logging.Logger.root]);
}

void initLoggers(logging.Level level, List<logging.Logger> loggers) {
  logging.hierarchicalLoggingEnabled = true;

  for (final logger in loggers) {
    logger
      ..level = level
      ..onRecord.listen(printLog);
  }
}

void deactivateLoggers(List<logging.Logger> loggers) {
  for (final logger in loggers) {
    logger.clearListeners();
  }
}

void printLog(record) {
  print('${record.level.name}: ${record.time}: ${record.message}');
}

// TODO: get rid of this custom Logger when all references are replaced with logging package
class Logger {
  static bool _printLogs = true;
  static void setLoggingMode(bool enabled) {
    _printLogs = enabled;
  }

  Logger({
    required scope,
  }) : _scope = scope;

  final String _scope;

  void log(String tag, String message, [Exception? exception]) {
    if (!Logger._printLogs) {
      return;
    }

    print('[$_scope] - $tag: $message');
    if (exception != null) {
      print(' - ${exception.toString()}');
    }
  }
}

import 'package:intl/intl.dart';

String timeAgo(DateTime? moment, {DateTime? now}) {
  if (moment == null) return 'Never';
  final diff = (now ?? DateTime.now()).difference(moment);
  if (diff.inSeconds < 45) return 'Just now';
  if (diff.inMinutes < 1) return '1 minute ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} ago';
  if (diff.inHours < 24) return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
  if (diff.inDays < 7) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  return DateFormat('d MMM yyyy').format(moment);
}

String clockTime(DateTime moment) => DateFormat('h:mm a').format(moment);

String dateTime(DateTime moment) => DateFormat('d MMM, h:mm a').format(moment);

String headerDate(DateTime moment) => DateFormat('EEE, dd MMM yyyy').format(moment);

String latitude(double v) => '${v.abs().toStringAsFixed(4)}° ${v >= 0 ? 'N' : 'S'}';

String longitude(double v) => '${v.abs().toStringAsFixed(4)}° ${v >= 0 ? 'E' : 'W'}';

String accuracy(double metres) =>
    metres < 1000 ? '± ${metres.round()} metres' : '± ${(metres / 1000).toStringAsFixed(1)} km';

String greeting(DateTime now) {
  final h = now.hour;
  if (h < 12) return 'Good Morning!';
  if (h < 17) return 'Good Afternoon!';
  return 'Good Evening!';
}

String minutes(int total) {
  if (total < 60) return '${total}m';
  return '${total ~/ 60}h ${total % 60}m';
}

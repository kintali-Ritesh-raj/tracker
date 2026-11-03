import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import 'theme.dart';

/// Frosted card: translucent white over the cream background with a soft shadow.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = AppRadius.card,
    this.onTap,
    this.blur = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  /// Real backdrop blur is costly; enable it only for cards floating over the map.
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    Widget body = Material(
      color: Colors.white.withValues(alpha: blur ? 0.78 : 0.86),
      borderRadius: shape,
      child: InkWell(
        borderRadius: shape,
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: Padding(padding: padding, child: child),
      ),
    );
    if (blur) {
      body = BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: body);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: AppShadow.soft,
        border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
      ),
      child: ClipRRect(borderRadius: shape, child: body),
    );
  }
}

/// Cream page background with the soft orange wave from the reference design.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child, this.skyline = false});

  final Widget child;
  final bool skyline;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFBF7), AppColors.cream, AppColors.creamDeep],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 220,
            child: IgnorePointer(child: CustomPaint(painter: _WavePainter(skyline: skyline))),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.skyline});
  final bool skyline;

  @override
  void paint(Canvas canvas, Size size) {
    if (skyline) {
      final building = Paint()..color = AppColors.orange.withValues(alpha: 0.07);
      final rnd = [0.55, 0.8, 0.45, 0.95, 0.6, 0.75, 0.5, 0.85];
      final w = size.width / rnd.length;
      for (var i = 0; i < rnd.length; i++) {
        final h = size.height * 0.55 * rnd[i];
        canvas.drawRRect(
          RRect.fromLTRBR(i * w + w * 0.18, size.height * 0.62 - h, i * w + w * 0.82, size.height, const Radius.circular(4)),
          building,
        );
      }
    }
    final back = Path()
      ..moveTo(0, size.height * 0.62)
      ..cubicTo(size.width * 0.3, size.height * 0.42, size.width * 0.6, size.height * 0.86, size.width, size.height * 0.5)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      back,
      Paint()
        ..shader = LinearGradient(
          colors: [AppColors.orange.withValues(alpha: 0.10), AppColors.orange.withValues(alpha: 0.22)],
        ).createShader(Offset.zero & size),
    );
    final front = Path()
      ..moveTo(0, size.height * 0.82)
      ..cubicTo(size.width * 0.35, size.height * 0.66, size.width * 0.7, size.height * 0.98, size.width, size.height * 0.72)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(front, Paint()..color = AppColors.orange.withValues(alpha: 0.12));
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.skyline != skyline;
}

/// "← Title" header used on every pushed screen.
class BackHeader extends StatelessWidget {
  const BackHeader({super.key, required this.title, this.trailing, this.onBack});

  final String title;
  final Widget? trailing;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop() || onBack != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
      child: Row(
        children: [
          if (canPop)
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back_rounded, size: 26),
              onPressed: onBack ?? () => Navigator.of(context).maybePop(),
            )
          else
            const SizedBox(width: 12),
          const SizedBox(width: 4),
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge, overflow: TextOverflow.ellipsis),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color, this.solid = true, this.dense = false});

  StatusPill.employee(EmployeeStatus status, {Key? key, bool dense = false})
      : this(key: key, label: status.label, color: AppColors.status(status), dense: dense);

  StatusPill.request(RequestStatus status, {Key? key})
      : this(key: key, label: status.label, color: AppColors.request(status), solid: false);

  final String label;
  final Color color;
  final bool solid;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final fg = solid ? Colors.white : color;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 12, vertical: dense ? 3 : 6),
      decoration: BoxDecoration(
        color: solid ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: dense ? 6 : 8, height: dense ? 6 : 8, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          SizedBox(width: dense ? 5 : 7),
          Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: dense ? 11.5 : 14)),
        ],
      ),
    );
  }
}

/// Employee photo from the backend (authenticated) with an initials fallback.
class EmployeeAvatar extends StatelessWidget {
  const EmployeeAvatar({super.key, required this.employee, required this.api, this.size = 48, this.ring});

  final Employee employee;
  final ApiClient api;
  final double size;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: AppColors.orangeSoft,
      alignment: Alignment.center,
      child: Text(
        employee.initials,
        style: TextStyle(color: AppColors.orangeDeep, fontWeight: FontWeight.w700, fontSize: size * 0.36),
      ),
    );
    final image = employee.hasPhoto
        ? Image.network(
            api.photoUrl(employee.id, employee.photoVersion),
            headers: api.imageHeaders,
            fit: BoxFit.cover,
            width: size,
            height: size,
            cacheWidth: (size * 3).round(),
            errorBuilder: (_, _, _) => fallback,
          )
        : fallback;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(ring == null ? 0 : size * 0.05),
      decoration: BoxDecoration(color: ring ?? Colors.transparent, shape: BoxShape.circle),
      child: ClipOval(child: SizedBox.expand(child: image)),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled || busy ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFFFB923C), AppColors.orangeDeep]),
          borderRadius: BorderRadius.circular(18),
          boxShadow: enabled ? AppShadow.button : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: enabled
                ? () {
                    HapticFeedback.lightImpact();
                    onPressed!();
                  }
                : null,
            child: SizedBox(
              height: 56,
              child: Center(
                child: busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[Icon(icon, color: Colors.white, size: 24), const SizedBox(width: 12)],
                          Text(label, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Orange icon on a soft orange disc, as on the Employee Details actions.
class IconDisc extends StatelessWidget {
  const IconDisc({super.key, required this.icon, this.size = 44, this.color = AppColors.orange});

  final IconData icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
      child: Icon(icon, color: color, size: size * 0.52),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(
        children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
          ?action,
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconDisc(icon: icon, size: 64),
          const SizedBox(height: 16),
          Text(title, style: t.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(message, style: t.bodyMedium, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}

/// Inline error with retry; used whenever a load fails.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(color: AppColors.offlineSoft, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: AppColors.offline, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(color: Color(0xFF991B1B), fontSize: 13.5))),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// SLG Housekeeping & Facility Services wordmark with the building mark.
class SlgLogo extends StatelessWidget {
  const SlgLogo({super.key, this.height = 56});
  final double height;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: height * 1.45, height: height, child: CustomPaint(painter: _LogoMark())),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('SLG',
                style: TextStyle(
                    fontSize: height * 0.48, fontWeight: FontWeight.w800, color: AppColors.orangeDeep, height: 1, letterSpacing: -0.5)),
            const SizedBox(height: 2),
            Text('Housekeeping &\nFacility Services',
                style: TextStyle(fontSize: height * 0.23, fontWeight: FontWeight.w600, color: AppColors.ink, height: 1.1)),
          ],
        ),
      ],
    );
  }
}

class _LogoMark extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final orange = Paint()..color = AppColors.orange;
    final deep = Paint()..color = AppColors.orangeDeep;
    final window = Paint()..color = Colors.white;
    // Swoosh roof line.
    final swoosh = Path()
      ..moveTo(0, s.height * 0.62)
      ..quadraticBezierTo(s.width * 0.45, s.height * 0.02, s.width, s.height * 0.22)
      ..quadraticBezierTo(s.width * 0.45, s.height * 0.16, s.width * 0.04, s.height * 0.7)
      ..close();
    canvas.drawPath(swoosh, deep);
    // Buildings.
    final blocks = [
      Rect.fromLTWH(s.width * 0.12, s.height * 0.55, s.width * 0.2, s.height * 0.45),
      Rect.fromLTWH(s.width * 0.34, s.height * 0.32, s.width * 0.28, s.height * 0.68),
      Rect.fromLTWH(s.width * 0.64, s.height * 0.46, s.width * 0.24, s.height * 0.54),
    ];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      canvas.drawRect(b, i == 1 ? deep : orange);
      final cols = 2, rows = (b.height / (s.height * 0.14)).floor();
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          final w = b.width * 0.22, h = s.height * 0.07;
          canvas.drawRect(
            Rect.fromLTWH(b.left + b.width * (0.18 + c * 0.42), b.top + s.height * 0.06 + r * s.height * 0.14, w, h),
            window,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

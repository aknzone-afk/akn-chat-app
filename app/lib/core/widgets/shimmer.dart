import 'package:flutter/material.dart';

/// The Flutter cookbook's shimmer, with one idea at its centre: **each
/// placeholder must not animate on its own clock**. One [AnimationController]
/// drives one [LinearGradient] sized to the whole [Shimmer] ancestor, and every
/// [ShimmerLoading] descendant shades the correct *slice* of that shared
/// gradient. A bag of independently blinking boxes reads as broken; one
/// highlight sweeping across the screen reads as loading.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child, this.gradient});

  final Widget child;
  final LinearGradient? gradient;

  static ShimmerState? of(BuildContext context) =>
      context.findAncestorStateOfType<ShimmerState>();

  static LinearGradient gradientFor(ColorScheme scheme) {
    final base = scheme.onSurface.withValues(alpha: 0.06);
    final highlight = scheme.onSurface.withValues(alpha: 0.14);
    return LinearGradient(
      colors: [base, base, highlight, base, base],
      stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
      begin: const Alignment(-1.0, -0.3),
      end: const Alignment(1.0, 0.3),
      tileMode: TileMode.clamp,
    );
  }

  @override
  State<Shimmer> createState() => ShimmerState();
}

class ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController.unbounded(vsync: this)
        ..repeat(
          min: -0.5,
          max: 1.5,
          period: const Duration(milliseconds: 1100),
        );

  late LinearGradient _gradient;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gradient = widget.gradient ?? Shimmer.gradientFor(Theme.of(context).colorScheme);
  }

  Listenable get shimmerChanges => _controller;

  bool get isSized =>
      (context.findRenderObject() as RenderBox?)?.hasSize ?? false;

  Size get size => (context.findRenderObject() as RenderBox).size;

  Offset getDescendantOffset({required RenderBox descendant, Offset offset = Offset.zero}) {
    final shimmerBox = context.findRenderObject() as RenderBox;
    return descendant.localToGlobal(offset, ancestor: shimmerBox);
  }

  LinearGradient get gradient => LinearGradient(
    colors: _gradient.colors,
    stops: _gradient.stops,
    begin: _gradient.begin,
    end: _gradient.end,
    transform: _SlidingGradientTransform(slidePercent: _controller.value),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform({required this.slidePercent});

  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * slidePercent, 0.0, 0.0);
}

/// One bone. Paints its child with the slice of the ancestor's gradient that
/// sits under it, which is what makes the highlight look continuous.
class ShimmerLoading extends StatefulWidget {
  const ShimmerLoading({super.key, required this.isLoading, required this.child});

  final bool isLoading;
  final Widget child;

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading> {
  Listenable? _shimmerChanges;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shimmerChanges?.removeListener(_onShimmerChange);
    _shimmerChanges = Shimmer.of(context)?.shimmerChanges;
    _shimmerChanges?.addListener(_onShimmerChange);
  }

  @override
  void dispose() {
    _shimmerChanges?.removeListener(_onShimmerChange);
    super.dispose();
  }

  void _onShimmerChange() {
    if (widget.isLoading && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) return widget.child;

    final shimmer = Shimmer.of(context);
    if (shimmer == null || !shimmer.isSized) {
      // The ancestor has not been laid out yet; next frame will paint properly.
      return const SizedBox.shrink();
    }

    final shimmerSize = shimmer.size;
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return const SizedBox.shrink();
    final offsetWithin = shimmer.getDescendantOffset(descendant: renderBox);

    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (bounds) => shimmer.gradient.createShader(
        Rect.fromLTWH(
          -offsetWithin.dx,
          -offsetWithin.dy,
          shimmerSize.width,
          shimmerSize.height,
        ),
      ),
      child: widget.child,
    );
  }
}

/// A grey rounded block — the shape every skeleton is built from.
class Bone extends StatelessWidget {
  const Bone({
    super.key,
    required this.width,
    required this.height,
    this.radius = 6,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => ShimmerLoading(
    isLoading: true,
    child: Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(radius),
      ),
    ),
  );
}

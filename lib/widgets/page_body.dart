import 'package:material_ui/material_ui.dart';

/// How wide a page's content gets on a wide window: the whole page. Kept
/// as a setting in one place in case a limit is wanted again.
const pageContentWidth = double.infinity;

/// [base] padding, widened on the right so content stays [maxWidth] wide
/// in a window of [width].
EdgeInsets readablePadding(
  double width,
  EdgeInsets base, {
  double maxWidth = pageContentWidth,
}) {
  final extra = width - maxWidth - base.horizontal;
  return extra > 0 ? base.copyWith(right: base.right + extra) : base;
}

/// A full-width scrolling page (content no wider than [pageContentWidth]).
class PageListView extends StatelessWidget {
  const PageListView({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListView(
      padding: readablePadding(constraints.maxWidth, padding),
      children: children,
    ),
  );
}

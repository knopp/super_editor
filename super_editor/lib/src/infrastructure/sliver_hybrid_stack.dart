import "package:flutter/rendering.dart";
import "package:flutter/widgets.dart";

class SliverHybridStack extends MultiChildRenderObjectWidget {
  const SliverHybridStack({
    super.key,
    super.children,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSliverHybridStack();
  }
}

class _ChildParentData extends SliverLogicalParentData with ContainerParentDataMixin<RenderObject> {}

class _RenderSliverHybridStack extends RenderSliver
    with ContainerRenderObjectMixin<RenderObject, ContainerParentDataMixin<RenderObject>>, RenderSliverHelpers {
  _RenderSliverHybridStack();

  @override
  void performLayout() {
    RenderSliver? sliver;
    var child = firstChild;
    while (child != null) {
      if (child is RenderSliver) {
        assert(sliver == null, "There can only be one sliver in a SliverHybridStack");
        sliver = child;
        break;
      }
      child = childAfter(child);
    }
    if (sliver == null) {
      geometry = SliverGeometry.zero;
      return;
    }
    (sliver.parentData! as SliverLogicalParentData).layoutOffset = 0.0;
    sliver.layout(constraints, parentUsesSize: true);
    final SliverGeometry sliverLayoutGeometry = sliver.geometry!;
    if (sliverLayoutGeometry.scrollOffsetCorrection != null) {
      geometry = SliverGeometry(
        scrollOffsetCorrection: sliverLayoutGeometry.scrollOffsetCorrection,
      );
      return;
    }
    geometry = SliverGeometry(
      scrollExtent: sliverLayoutGeometry.scrollExtent,
      paintExtent: sliverLayoutGeometry.paintExtent,
      maxPaintExtent: sliverLayoutGeometry.maxPaintExtent,
      maxScrollObstructionExtent: sliverLayoutGeometry.maxScrollObstructionExtent,
      cacheExtent: sliverLayoutGeometry.cacheExtent,
      hasVisualOverflow: sliverLayoutGeometry.hasVisualOverflow,
    );

    final boxConstraints = ScrollingBoxConstraints(
      minWidth: constraints.crossAxisExtent,
      maxWidth: constraints.crossAxisExtent,
      minHeight: sliverLayoutGeometry.scrollExtent,
      maxHeight: sliverLayoutGeometry.scrollExtent,
      scrollOffset: constraints.scrollOffset,
    );

    child = firstChild;
    while (child != null) {
      if (child is RenderBox) {
        final childParentData = child.parentData! as SliverLogicalParentData;
        childParentData.layoutOffset = -constraints.scrollOffset;
        child.layout(boxConstraints, parentUsesSize: true);
      }
      child = childAfter(child);
    }
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    assert(geometry!.hitTestExtent > 0.0);
    var child = lastChild;
    while (child != null) {
      if (child is RenderSliver) {
        final isHit = child.hitTest(
          result,
          mainAxisPosition: mainAxisPosition,
          crossAxisPosition: crossAxisPosition,
        );
        if (isHit) {
          return true;
        }
      } else if (child is RenderBox) {
        final boxResult = BoxHitTestResult.wrap(result);
        final isHit =
            hitTestBoxChild(boxResult, child, mainAxisPosition: mainAxisPosition, crossAxisPosition: crossAxisPosition);
        if (isHit) {
          return true;
        }
      }
      child = childBefore(child);
    }
    return false;
  }

  @override
  void setupParentData(covariant RenderObject child) {
    child.parentData = _ChildParentData();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var child = firstChild;
    while (child != null) {
      final childParentData = child.parentData! as SliverLogicalParentData;
      context.paintChild(
        child,
        offset + Offset(0, childParentData.layoutOffset!),
      );
      child = childAfter(child);
    }
  }

  @override
  void applyPaintTransform(covariant RenderObject child, Matrix4 transform) {
    final childParentData = child.parentData! as SliverLogicalParentData;
    transform.translate(0.0, childParentData.layoutOffset!);
  }

  @override
  double childMainAxisPosition(covariant RenderObject child) {
    final childParentData = child.parentData! as SliverLogicalParentData;
    return childParentData.layoutOffset!;
  }
}

// Box constraints that will cause relayout when the scroll offset changes.
class ScrollingBoxConstraints extends BoxConstraints {
  const ScrollingBoxConstraints({
    super.minWidth,
    super.maxWidth,
    super.minHeight,
    super.maxHeight,
    required this.scrollOffset,
  });

  final double scrollOffset;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ScrollingBoxConstraints && super == other && scrollOffset == other.scrollOffset;
  }

  @override
  int get hashCode => Object.hash(super.hashCode, scrollOffset);
}

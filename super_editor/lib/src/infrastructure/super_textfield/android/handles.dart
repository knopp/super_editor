import 'dart:math';

import 'package:flutter/material.dart';

class AndroidTextfieldCollapsedHandle extends StatelessWidget {
  const AndroidTextfieldCollapsedHandle({
    Key? key,
    required this.color,
    required this.radius,
  }) : super(key: key);

  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -pi / 4,
      child: Container(
        width: radius * 2,
        height: radius * 2,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(radius),
            bottomLeft: Radius.circular(radius),
            bottomRight: Radius.circular(radius),
          ),
        ),
      ),
    );
  }
}

class AndroidTextfieldLeftHandle extends StatelessWidget {
  const AndroidTextfieldLeftHandle({
    Key? key,
    required this.color,
    required this.radius,
  }) : super(key: key);

  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(radius),
          bottomLeft: Radius.circular(radius),
          bottomRight: Radius.circular(radius),
        ),
      ),
    );
  }
}

class AndroidTextfieldRightHandle extends StatelessWidget {
  const AndroidTextfieldRightHandle({
    Key? key,
    required this.color,
    required this.radius,
  }) : super(key: key);

  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(radius),
          bottomLeft: Radius.circular(radius),
          bottomRight: Radius.circular(radius),
        ),
      ),
    );
  }
}

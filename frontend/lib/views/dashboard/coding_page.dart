import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart';

class CodingPage extends StatefulWidget {
  const CodingPage({super.key});

  @override
  State<CodingPage> createState() => _CodingPageState();
}

class _CodingPageState extends State<CodingPage> with TickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  // دالة لبناء أقسام التكويد (موردين، تصنيفات، إلخ)
  Widget _buildCodingSection({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
    required double delay,
  }) {
    return FadeTransition(
      opacity: _animController,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero)
            .animate(CurvedAnimation(
          parent: _animController,
          curve: Interval(delay, 1.0, curve: Curves.easeOut),
        )),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: InkWell(
            onTap: onTap,
            child: GlassCard(
              child: ListTile(
                leading: Icon(icon, color: Colors.white, size: 30),
                title: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                trailing: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white70, size: 18),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A237E), Color(0xFF3949AB)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // الهيدر
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
                    ),
                    const Text(
                      "صفحة التكويد",
                      style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              // تكملة الـ Column داخل الـ SafeArea
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    const SizedBox(height: 10),
                    
                    // قسم تكويد الموردين
                    _buildCodingSection(
                      title: "تكويد الموردين",
                      icon: Icons.person_add_alt_1_rounded,
                      onTap: () => _openCodingModal("الموردين"),
                      delay: 0.2,
                    ),

                    // قسم تكويد التصنيفات (وارد / دفعة)
                    _buildCodingSection(
                      title: "تكويد التصنيفات",
                      icon: Icons.category_rounded,
                      onTap: () => _openCodingModal("التصنيفات"),
                      delay: 0.4,
                    ),

                    // قسم تكويد الوظائف والأدوار
                    _buildCodingSection(
                      title: "تكويد الوظائف (الصلاحيات)",
                      icon: Icons.admin_panel_settings_rounded,
                      onTap: () => _openCodingModal("الوظائف"),
                      delay: 0.6,
                    ),

                    // قسم تكويد الأكواد المسموحة للشركات
                    _buildCodingSection(
                      title: "أكواد الشركات المتعاقدة",
                      icon: Icons.business_rounded,
                      onTap: () => _openCodingModal("الشركات"),
                      delay: 0.8,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // دالة لفتح نافذة إدخال الكود الجديد (Bottom Sheet زجاجي)
  void _openCodingModal(String type) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent, // عشان يبان التأثير الزجاجي
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "إضافة كود جديد لـ $type",
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              _buildModalField("الاسم / المسمى", Icons.edit),
              const SizedBox(height: 15),
              _buildModalField("الكود التعريفي", Icons.numbers),
              const SizedBox(height: 25),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF1A237E),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  ),
                  child: const Text("حفظ الكود محلياً", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModalField(String label, IconData icon) {
    return TextField(
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: Colors.white70),
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(15)),
      ),
    );
  }
}
  
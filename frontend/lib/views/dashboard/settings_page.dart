import 'package:flutter/material.dart';
import '../../main.dart'; // مهم عشان نوصل لـ IslamApp
import '../widgets/glass_card.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    // نعرف حالة الثيم الحالية من الـ main
    bool isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text("الإعدادات", style: TextStyle(fontFamily: 'Cairo')),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDarkMode 
                ? [const Color(0xFF0D1117), const Color(0xFF161B22)] 
                : [const Color(0xFFF0F2F5), Colors.white],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              children: [
                // كارت التحكم في الثيم
                GlassCard(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isDarkMode ? Icons.dark_mode : Icons.light_mode,
                            color: isDarkMode ? Colors.cyanAccent : Colors.orangeAccent,
                          ),
                          const SizedBox(width: 15),
                          const Text(
                            "الوضع الليلي",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ],
                      ),
                      Switch(
                        value: isDarkMode,
                        activeColor: Colors.cyanAccent,
                        onChanged: (value) {
                          // بننادي الدالة اللي في الـ main لتغيير الثيم
                          IslamApp.of(context).changeTheme(
                            value ? ThemeMode.dark : ThemeMode.light,
                          );
                        },
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 20),

                // أزرار برمجية للمستقبل
                _buildSettingsButton(
                  icon: Icons.person_outline,
                  label: "تعديل الملف الشخصي",
                  onTap: () {
                    // هنبرمجها بعدين
                  },
                ),
                
                _buildSettingsButton(
                  icon: Icons.backup_outlined,
                  label: "النسخ الاحتياطي",
                  onTap: () {
                    // هنبرمجها بعدين
                  },
                ),

                _buildSettingsButton(
                  icon: Icons.info_outline,
                  label: "عن التطبيق",
                  onTap: () {
                    // هنبرمجها بعدين
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Widget مساعد لعمل الأزرار بشكل متناسق
  Widget _buildSettingsButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: GlassCard(
          child: Row(
            children: [
              Icon(icon, color: Colors.white70),
              const SizedBox(width: 15),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontFamily: 'Cairo',
                ),
              ),
              const Spacer(),
              const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }
}
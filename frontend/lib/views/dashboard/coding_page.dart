import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/api_service.dart';

class CodingPage extends StatefulWidget {
  final String companyCode; // لازم نمرر كود الشركة عشان نفصل البيانات
  const CodingPage({super.key, required this.companyCode});

  @override
  State<CodingPage> createState() => _CodingPageState();
}

class _CodingPageState extends State<CodingPage> with TickerProviderStateMixin {
  late AnimationController _animController;
  final ApiService _apiService = ApiService();
  
  // وحدات التحكم في الإدخال
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  
  bool _isLoading = false;

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
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  // 1. دالة لجلب البيانات وفتح شاشة الإدارة
  void _openManageModal(String category, String title) async {
    setState(() => _isLoading = true);
    try {
      List<dynamic> items = await _apiService.getCodingData(widget.companyCode, category);
      setState(() => _isLoading = false);

      if (!mounted) return;
      
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => _buildManagerSheet(title, category, items),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar("خطأ: $e", Colors.redAccent);
    }
  }

  // 2. واجهة إدارة التكويدات (القائمة)
  Widget _buildManagerSheet(String title, String category, List<dynamic> items) {
    return StatefulBuilder(
      builder: (context, setModalState) => Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: const BoxDecoration(
          color: Color(0xFF1E293B),
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 15),
            Container(width: 50, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10))),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("إدارة $title", style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                  ElevatedButton.icon(
                    onPressed: () => _showAddEditDialog(category, title, null, setModalState, items),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text("إضافة"),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty 
                ? const Center(child: Text("لا توجد بيانات مسجلة", style: TextStyle(color: Colors.white38)))
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ListTile(
                        leading: CircleAvatar(backgroundColor: Colors.white10, child: Text("${index + 1}", style: const TextStyle(color: Colors.white70))),
                        title: Text(item['name'], style: const TextStyle(color: Colors.white)),
                        subtitle: Text("كود: ${item['code']}", style: const TextStyle(color: Colors.white38)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.orangeAccent, size: 20),
                              onPressed: () => _showAddEditDialog(category, title, item, setModalState, items),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_forever, color: Colors.redAccent, size: 20),
                              onPressed: () => _confirmDelete(category, item['code'], setModalState, items, index),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
            ),
          ],
        ),
      ),
    );
  }

  // 3. ديالوج الإضافة أو التعديل
  void _showAddEditDialog(String category, String title, Map<String, dynamic>? existingItem, Function setModalState, List items) {
    bool isEdit = existingItem != null;
    if (isEdit) {
      _nameController.text = existingItem['name'];
      _codeController.text = existingItem['code'];
    } else {
      _nameController.clear();
      _codeController.clear();
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(isEdit ? "تعديل $title" : "إضافة $title", style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: "الاسم", labelStyle: TextStyle(color: Colors.white60)),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _codeController,
              enabled: !isEdit, // الكود لا يُعدل لأنه المفتاح الأساسي
              style: TextStyle(color: isEdit ? Colors.white38 : Colors.white),
              decoration: const InputDecoration(labelText: "الكود", labelStyle: TextStyle(color: Colors.white60)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("إلغاء")),
          ElevatedButton(
            onPressed: () async {
              if (_nameController.text.isEmpty || _codeController.text.isEmpty) return;
              await _apiService.saveNewCode(widget.companyCode, category, _codeController.text, _nameController.text);
              Navigator.pop(context);
              _refreshInModal(category, setModalState, items);
              _showSnackBar("تم الحفظ بنجاح", Colors.green);
            },
            child: const Text("حفظ"),
          ),
        ],
      ),
    );
  }

  // 4. تأكيد الحذف
  void _confirmDelete(String category, String code, Function setModalState, List items, int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text("حذف؟", style: TextStyle(color: Colors.white)),
        content: const Text("سيتم حذف التكويد نهائياً، هل أنت متأكد؟", style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("إلغاء")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              await _apiService.deleteCode(widget.companyCode, category, code);
              Navigator.pop(context);
              _refreshInModal(category, setModalState, items);
              _showSnackBar("تم الحذف", Colors.blueGrey);
            },
            child: const Text("حذف"),
          ),
        ],
      ),
    );
  }

  // تحديث البيانات داخل الـ Modal بدون قفله
  void _refreshInModal(String category, Function setModalState, List items) async {
    var newData = await _apiService.getCodingData(widget.companyCode, category);
    setModalState(() {
      items.clear();
      items.addAll(newData);
    });
  }

  void _showSnackBar(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text("التكويد الأساسي"), backgroundColor: Colors.transparent, elevation: 0),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFF0F172A), Color(0xFF1E293B)]),
        ),
        child: SafeArea(
          child: _isLoading 
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _buildSection("تكويد الخزائن", Icons.account_balance_wallet, () => _openManageModal("safes", "الخزائن")),
                  _buildSection("تكويد الموردين", Icons.local_shipping, () => _openManageModal("suppliers", "الموردين")),
                  _buildSection("تكويد الأصناف", Icons.inventory_2, () => _openManageModal("items", "الأصناف")),
                  _buildSection("تكويد المصروفات", Icons.payments, () => _openManageModal("expenses", "المصروفات")),
                ],
              ),
        ),
      ),
    );
  }

  Widget _buildSection(String title, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: InkWell(
        onTap: onTap,
        child: GlassCard(
          child: Row(
            children: [
              Icon(icon, color: Colors.blueAccent, size: 28),
              const SizedBox(width: 20),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              const Icon(Icons.settings, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }
}
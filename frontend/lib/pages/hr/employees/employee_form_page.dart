// lib/pages/hr/employees/employee_form_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../core/theme.dart';
import '../../../views/widgets/glass_card.dart';
import '../../../services/employee_service.dart';
import '../../../services/permissions_service.dart';
import '../../../models/employee_model.dart';


/// صفحة إضافة / تعديل موظف
///
/// 5 أقسام:
///   1. البيانات الأساسية (code, name, phone, email)
///   2. البيانات الشخصية (nationalId, gender, birthDate, address)
///   3. البيانات الوظيفية (jobTitle, department, branchCode,
///      salary, contractType, status, hireDate, endDate)
///   4. ربط Firebase (userUid, userEmail)
///   5. بيانات إضافية (emergencyContact, bankName, bankAccount, notes)
///
/// - يعمل في وضعين: إضافة (employee == null) / تعديل
/// - تحققات كاملة + منع تكرار الكود
/// - Alert قبل الإلغاء لو فيه تعديلات
class EmployeeFormPage extends StatefulWidget {
  final String companyCode;
  final EmployeeModel? employee; // null = إضافة

  const EmployeeFormPage({
    super.key,
    required this.companyCode,
    this.employee,
  });

  @override
  State<EmployeeFormPage> createState() => _EmployeeFormPageState();
}


class _EmployeeFormPageState extends State<EmployeeFormPage> {
  // ============================================================
  // Services
  // ============================================================

  final EmployeeService _employeeService = EmployeeService();


  // ============================================================
  // State
  // ============================================================

  final _formKey = GlobalKey<FormState>();

  bool _isSaving = false;
  bool _hasChanges = false;
  bool get _isEditMode => widget.employee != null;

  List<Map<String, String>> _branches = [];


  // ============================================================
  // Controllers (كل حقل له controller)
  // ============================================================

  // 1. أساسية
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  // 2. شخصية
  final _nationalIdCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();

  // 3. وظيفية
  final _jobTitleCtrl = TextEditingController();
  final _departmentCtrl = TextEditingController();
  final _salaryCtrl = TextEditingController();

  // 4. Firebase
  final _userUidCtrl = TextEditingController();
  final _userEmailCtrl = TextEditingController();

  // 5. إضافية
  final _emergencyCtrl = TextEditingController();
  final _bankNameCtrl = TextEditingController();
  final _bankAccountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();


  // ============================================================
  // Dropdown values
  // ============================================================

  String _gender = '';
  String _contractType = '';
  String _status = 'active';
  String? _branchCode;
  DateTime? _birthDate;
  DateTime? _hireDate;
  DateTime? _endDate;


  // ============================================================
  // Lifecycle
  // ============================================================

  @override
  void initState() {
    super.initState();
    _loadBranches();
    _initializeForm();
    _attachListeners();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _nationalIdCtrl.dispose();
    _addressCtrl.dispose();
    _jobTitleCtrl.dispose();
    _departmentCtrl.dispose();
    _salaryCtrl.dispose();
    _userUidCtrl.dispose();
    _userEmailCtrl.dispose();
    _emergencyCtrl.dispose();
    _bankNameCtrl.dispose();
    _bankAccountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }


  void _attachListeners() {
    final controllers = [
      _codeCtrl, _nameCtrl, _phoneCtrl, _emailCtrl,
      _nationalIdCtrl, _addressCtrl, _jobTitleCtrl, _departmentCtrl,
      _salaryCtrl, _userUidCtrl, _userEmailCtrl,
      _emergencyCtrl, _bankNameCtrl, _bankAccountCtrl, _notesCtrl,
    ];
    for (final c in controllers) {
      c.addListener(_markChanged);
    }
  }


  void _markChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }


  // ============================================================
  // Load branches
  // ============================================================

  void _loadBranches() {
    final box = Hive.box('coding_box');
    final key = '${widget.companyCode}_branches';
    final raw = box.get(key);

    _branches = [];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final code = item['code']?.toString() ?? '';
        final name = item['name']?.toString() ?? '';
        if (code.isEmpty) continue;
        _branches.add({'code': code, 'name': name});
      }
    }
  }


  // ============================================================
  // Initialize form (edit mode)
  // ============================================================

  void _initializeForm() {
    final emp = widget.employee;
    if (emp == null) return;

    _codeCtrl.text = emp.code;
    _nameCtrl.text = emp.name;
    _phoneCtrl.text = emp.phone;
    _emailCtrl.text = emp.email;
    _nationalIdCtrl.text = emp.nationalId;
    _addressCtrl.text = emp.address;
    _gender = emp.gender;
    _jobTitleCtrl.text = emp.jobTitle;
    _departmentCtrl.text = emp.department;
    _branchCode = emp.branchCode.isNotEmpty ? emp.branchCode : null;
        // ⭐ إخفاء قيمة الراتب لو المستخدم مش عنده صلاحية
    final canSeeSalary = PermissionsService().canSeeEmployeeSalary(emp.code);
    _salaryCtrl.text =
        canSeeSalary && emp.salary > 0 ? emp.salary.toString() : '';
    _contractType = emp.contractType;
    _status = emp.status.isNotEmpty ? emp.status : 'active';
    _userUidCtrl.text = emp.userUid;
    _userEmailCtrl.text = emp.userEmail;
    _emergencyCtrl.text = emp.emergencyContact;
    _bankNameCtrl.text = emp.bankName;
    _bankAccountCtrl.text = emp.bankAccount;
    _notesCtrl.text = emp.notes;

    _birthDate = _parseDate(emp.birthDate);
    _hireDate = _parseDate(emp.hireDate);
    _endDate = _parseDate(emp.endDate);
  }


  DateTime? _parseDate(String value) {
    if (value.isEmpty) return null;
    try {
      return DateTime.parse(value);
    } catch (_) {
      return null;
    }
  }


  String _dateToStr(DateTime? date) {
    if (date == null) return '';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }


  String _displayDate(DateTime? date) {
    if (date == null) return '';
    return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
  }


  // ============================================================
  // Date picker
  // ============================================================

  Future<void> _pickDate({
    required String label,
    required DateTime? current,
    required Function(DateTime?) onPicked,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(1950),
      lastDate: DateTime(2100),
      helpText: label,
    );
    if (picked != null) {
      setState(() {
        onPicked(picked);
        _hasChanges = true;
      });
    }
  }


  // ============================================================
  // Save
  // ============================================================

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      _showSnackBar(
        "يرجى تصحيح الأخطاء أولاً",
        AppTheme.warningOrangeFor(context),
      );
      return;
    }

        final codeTrimmed = _codeCtrl.text.trim();

    // ⭐ فحص تكرار الكود (فقط لو معبأ وفي وضع التعديل أو المستخدم كتبه)
    if (codeTrimmed.isNotEmpty) {
      final codeTaken = await _isCodeTaken(codeTrimmed);
      if (codeTaken) {
        _showSnackBar(
          "الكود [$codeTrimmed] مستخدم بالفعل",
          AppTheme.dangerStrongFor(context),
        );
        return;
      }
    }

    setState(() => _isSaving = true);

    try {
      final model = EmployeeModel(
        code: codeTrimmed,
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        nationalId: _nationalIdCtrl.text.trim(),
        address: _addressCtrl.text.trim(),
        gender: _gender,
        birthDate: _dateToStr(_birthDate),
        jobTitle: _jobTitleCtrl.text.trim(),
        department: _departmentCtrl.text.trim(),
        branchCode: _branchCode ?? '',
        hireDate: _dateToStr(_hireDate),
        endDate: _dateToStr(_endDate),
                // ⭐ لو مش عنده صلاحية، نستخدم القيمة الأصلية (في وضع التعديل) أو 0 (في وضع الإضافة)
        salary: _isEditMode
            ? (PermissionsService()
                    .canSeeEmployeeSalary(widget.employee!.code)
                ? double.tryParse(_salaryCtrl.text.trim()) ?? 0.0
                : (widget.employee!.salary))   // ← احتفظ بالقيمة الأصلية
            : (double.tryParse(_salaryCtrl.text.trim()) ?? 0.0),
        contractType: _contractType,
        status: _status,
        userUid: _userUidCtrl.text.trim(),
        userEmail: _userEmailCtrl.text.trim(),
        emergencyContact: _emergencyCtrl.text.trim(),
        bankName: _bankNameCtrl.text.trim(),
        bankAccount: _bankAccountCtrl.text.trim(),
        notes: _notesCtrl.text.trim(),
      );

      final result = await _employeeService.saveEmployee(
        companyCode: widget.companyCode,
        model: model,
      );

      if (!mounted) return;

      if (result['success'] == true) {
        _showSnackBar(
          _isEditMode ? "تم تحديث الموظف" : "تم إضافة الموظف",
          AppTheme.successStrongFor(context),
        );
        Navigator.pop(context, true);
      } else {
        setState(() => _isSaving = false);
        _showSnackBar(
          "فشل الحفظ: ${result['error'] ?? 'خطأ غير معروف'}",
          AppTheme.dangerStrongFor(context),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _showSnackBar(
        "خطأ: $e",
        AppTheme.dangerStrongFor(context),
      );
    }
  }


  Future<bool> _isCodeTaken(String code) async {
    try {
      final list = await _employeeService.getEmployeesList(
        companyCode: widget.companyCode,
      );

      // في وضع التعديل: استثني نفس الموظف
      final originalCode = widget.employee?.code;

      for (final e in list) {
        if (e.code == code && e.code != originalCode) {
          return true;
        }
      }
      return false;
    } catch (_) {
      // لو فشل التحقق، اسمح بالمحاولة (الباك هيرفض لو مكرر)
      return false;
    }
  }


  // ============================================================
  // Cancel
  // ============================================================

  Future<void> _cancel() async {
    if (_hasChanges && !_isSaving) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.dialogBackground(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: Text(
            'تجاهل التعديلات؟',
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'لديك تعديلات لم تُحفظ. هل تريد تجاهلها والعودة؟',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'تراجع',
                style: TextStyle(
                  color: AppTheme.textMutedFor(context),
                  fontFamily: 'Cairo',
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'تجاهل',
                style: TextStyle(
                  color: AppTheme.dangerFor(context),
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );

      if (confirmed != true) return;
    }

    if (mounted) Navigator.pop(context);
  }


  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: color,
      ),
    );
  }


  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    // فحص الصلاحية
    if (!PermissionsService().canManageEmployees) {
      return _buildNoPermissionScreen();
    }

    return PopScope(
      canPop: !_hasChanges || _isSaving,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _cancel();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Text(
            _isEditMode ? "تعديل موظف" : "إضافة موظف",
            style: TextStyle(
              fontFamily: 'Cairo',
              color: AppTheme.textMainFor(context),
            ),
          ),
          centerTitle: true,
          backgroundColor: AppTheme.appBarBg,
          elevation: 0,
          iconTheme: IconThemeData(color: AppTheme.textMainFor(context)),
          actions: [
            if (_isSaving)
              Padding(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.accentFor(context),
                  ),
                ),
              )
            else
              IconButton(
                icon: Icon(
                  Icons.save_rounded,
                  color: _hasChanges
                      ? AppTheme.successStrongFor(context)
                      : AppTheme.textMutedFor(context),
                ),
                onPressed: _hasChanges ? _save : null,
                tooltip: 'حفظ',
              ),
          ],
        ),
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: AppTheme.dashGradientMain(context),
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSection1_Basic(),
                    const SizedBox(height: 16),
                    _buildSection2_Personal(),
                    const SizedBox(height: 16),
                    _buildSection3_Work(),
                    const SizedBox(height: 16),
                    _buildSection4_Firebase(),
                    const SizedBox(height: 16),
                    _buildSection5_Additional(),
                    const SizedBox(height: 20),
                    _buildBottomButtons(),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }


  // ============================================================
  // Section helpers
  // ============================================================

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required Color color,
    bool required = false,
    String? subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, right: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: AppTheme.textMainFor(context),
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (required)
                      Text(
                        ' *',
                        style: TextStyle(
                          color: AppTheme.dangerFor(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
    int? maxLength,
    int maxLines = 1,
    String? Function(String?)? validator,
    bool enabled = true,
    String? hint,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      maxLength: maxLength,
      maxLines: maxLines,
      enabled: enabled,
      validator: validator,
      style: TextStyle(
        color: AppTheme.textMainFor(context),
        fontFamily: 'Cairo',
        fontSize: 13,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        counterText: '', // يخفي عداد maxLength
        labelStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textMutedFor(context),
          fontSize: 12,
        ),
        hintStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textMutedFor(context).withValues(alpha: 0.5),
          fontSize: 12,
        ),
        prefixIcon: Icon(
          icon,
          color: AppTheme.accentFor(context),
          size: 18,
        ),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GlassStyle.line10For(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: AppTheme.accentFor(context),
            width: 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppTheme.dangerFor(context)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        isDense: true,
      ),
    );
  }


  Widget _buildDropdown<T>({
    required String label,
    required IconData icon,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    String? Function(T?)? validator,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      items: items,
      onChanged: onChanged,
      validator: validator,
      style: TextStyle(
        color: AppTheme.textMainFor(context),
        fontFamily: 'Cairo',
        fontSize: 13,
      ),
      dropdownColor: AppTheme.dropdownBackground(context),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          fontFamily: 'Cairo',
          color: AppTheme.textMutedFor(context),
          fontSize: 12,
        ),
        prefixIcon: Icon(
          icon,
          color: AppTheme.accentFor(context),
          size: 18,
        ),
        filled: true,
        fillColor: GlassStyle.fill05For(context),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GlassStyle.line10For(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: AppTheme.accentFor(context),
            width: 1.5,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        isDense: true,
      ),
    );
  }


  Widget _buildDateField({
    required String label,
    required IconData icon,
    required DateTime? value,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: GlassStyle.fill05For(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: GlassStyle.line10For(context)),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.accentFor(context), size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.textMutedFor(context),
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    value != null ? _displayDate(value) : '—',
                    style: TextStyle(
                      color: value != null
                          ? AppTheme.textMainFor(context)
                          : AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight:
                          value != null ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
            if (value != null && onClear != null)
              IconButton(
                icon: Icon(
                  Icons.clear_rounded,
                  size: 16,
                  color: AppTheme.dangerFor(context),
                ),
                onPressed: onClear,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              )
            else
              Icon(
                Icons.calendar_today_rounded,
                size: 14,
                color: AppTheme.textMutedFor(context),
              ),
          ],
        ),
      ),
    );
  }


  // ============================================================
  // Section 1: Basic data
  // ============================================================

  Widget _buildSection1_Basic() {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            icon: Icons.person_rounded,
            title: 'البيانات الأساسية',
            color: AppTheme.successFor(context),
            required: true,
          ),
          Row(
            children: [
                            Expanded(
                child: _buildTextField(
                  controller: _codeCtrl,
                  label: _isEditMode
                      ? 'الكود'
                      : 'الكود (تلقائي لو فاضي)',
                  icon: Icons.qr_code_rounded,
                  enabled: !_isEditMode,
                  hint: _isEditMode ? null : 'اتركه فاضي لتوليده',
                  validator: (v) {
                    // ⭐ في وضع التعديل، الكود إجباري
                    // في وضع الإضافة، مش إجباري (الباك يولّده)
                    if (_isEditMode && (v == null || v.trim().isEmpty)) {
                      return 'مطلوب';
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _buildTextField(
                  controller: _nameCtrl,
                  label: 'الاسم',
                  icon: Icons.badge_rounded,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'مطلوب';
                    }
                    return null;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  controller: _phoneCtrl,
                  label: 'الهاتف',
                  icon: Icons.phone_rounded,
                  keyboardType: TextInputType.phone,
                  maxLength: 20,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildTextField(
                  controller: _emailCtrl,
                  label: 'الإيميل',
                  icon: Icons.email_rounded,
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final email = v.trim();
                    if (!RegExp(r'^[\w\.-]+@[\w\.-]+\.[a-z]{2,}$',
                            caseSensitive: false)
                        .hasMatch(email)) {
                      return 'صيغة غير صحيحة';
                    }
                    return null;
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }


  // ============================================================
  // Section 2: Personal data
  // ============================================================

  Widget _buildSection2_Personal() {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            icon: Icons.contact_page_rounded,
            title: 'البيانات الشخصية',
            color: AppTheme.infoFor(context),
          ),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _buildTextField(
                  controller: _nationalIdCtrl,
                  label: 'الرقم القومي',
                  icon: Icons.credit_card_rounded,
                  keyboardType: TextInputType.number,
                  maxLength: 14,
                  formatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    if (v.trim().length != 14) {
                      return '14 رقم';
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildDropdown<String>(
                  label: 'الجنس',
                  icon: Icons.wc_rounded,
                  value: _gender.isEmpty ? null : _gender,
                  items: const [
                    DropdownMenuItem(
                      value: 'male',
                      child: Text('ذكر',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                    DropdownMenuItem(
                      value: 'female',
                      child: Text('أنثى',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _gender = v ?? '';
                      _hasChanges = true;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildDateField(
            label: 'تاريخ الميلاد',
            icon: Icons.cake_rounded,
            value: _birthDate,
            onTap: () => _pickDate(
              label: 'تاريخ الميلاد',
              current: _birthDate,
              onPicked: (d) => _birthDate = d,
            ),
            onClear: _birthDate != null
                ? () => setState(() {
                      _birthDate = null;
                      _hasChanges = true;
                    })
                : null,
          ),
          const SizedBox(height: 10),
          _buildTextField(
            controller: _addressCtrl,
            label: 'العنوان',
            icon: Icons.location_on_rounded,
            maxLines: 2,
          ),
        ],
      ),
    );
  }


  // ============================================================
  // Section 3: Work data
  // ============================================================

    Widget _buildSection3_Work() {
    // ⭐ هل يقدر يشوف الراتب؟
    final canSeeSalary = _isEditMode
        ? PermissionsService().canSeeEmployeeSalary(widget.employee!.code)
        : PermissionsService().canViewSalaryAmounts;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            icon: Icons.work_rounded,
            title: 'البيانات الوظيفية',
            color: AppTheme.warningFor(context),
          ),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  controller: _jobTitleCtrl,
                  label: 'المسمى الوظيفي',
                  icon: Icons.badge_outlined,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildTextField(
                  controller: _departmentCtrl,
                  label: 'القسم',
                  icon: Icons.category_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildDropdown<String?>(
                  label: 'الفرع',
                  icon: Icons.storefront_rounded,
                  value: _branchCode,
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('كل الفروع (موظف عام)',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                    ..._branches.map((b) => DropdownMenuItem<String?>(
                          value: b['code'],
                          child: Text(
                            b['name'] ?? '',
                            style: const TextStyle(fontFamily: 'Cairo'),
                          ),
                        )),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _branchCode = v;
                      _hasChanges = true;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildTextField(
                  controller: _salaryCtrl,
                  label: canSeeSalary ? 'الراتب' : 'الراتب (مخفي)',
                  icon: Icons.attach_money_rounded,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  enabled: canSeeSalary,   // ⭐
                  validator: (v) {
                    if (!canSeeSalary) return null;
                    if (v == null || v.trim().isEmpty) return null;
                    final n = double.tryParse(v.trim());
                    if (n == null || n < 0) {
                      return 'رقم غير صحيح';
                    }
                    return null;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildDropdown<String>(
                  label: 'نوع العقد',
                  icon: Icons.description_rounded,
                  value: _contractType.isEmpty ? null : _contractType,
                  items: const [
                    DropdownMenuItem(
                      value: 'permanent',
                      child: Text('دائم',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                    DropdownMenuItem(
                      value: 'temporary',
                      child: Text('مؤقت',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                    DropdownMenuItem(
                      value: 'part-time',
                      child: Text('دوام جزئي',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _contractType = v ?? '';
                      _hasChanges = true;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildDropdown<String>(
                  label: 'الحالة',
                  icon: Icons.verified_rounded,
                  value: _status,
                  items: const [
                    DropdownMenuItem(
                      value: 'active',
                      child: Text('نشط',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                    DropdownMenuItem(
                      value: 'on_leave',
                      child: Text('إجازة',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                    DropdownMenuItem(
                      value: 'suspended',
                      child: Text('موقوف',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                    DropdownMenuItem(
                      value: 'terminated',
                      child: Text('منتهي',
                          style: TextStyle(fontFamily: 'Cairo')),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _status = v ?? 'active';
                      _hasChanges = true;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildDateField(
                  label: 'تاريخ التعيين',
                  icon: Icons.event_available_rounded,
                  value: _hireDate,
                  onTap: () => _pickDate(
                    label: 'تاريخ التعيين',
                    current: _hireDate,
                    onPicked: (d) => _hireDate = d,
                  ),
                  onClear: _hireDate != null
                      ? () => setState(() {
                            _hireDate = null;
                            _hasChanges = true;
                          })
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildDateField(
                  label: 'تاريخ الانتهاء',
                  icon: Icons.event_busy_rounded,
                  value: _endDate,
                  onTap: () => _pickDate(
                    label: 'تاريخ الانتهاء',
                    current: _endDate,
                    onPicked: (d) => _endDate = d,
                  ),
                  onClear: _endDate != null
                      ? () => setState(() {
                            _endDate = null;
                            _hasChanges = true;
                          })
                      : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }


  // ============================================================
  // Section 4: Firebase link
  // ============================================================

  Widget _buildSection4_Firebase() {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            icon: Icons.link_rounded,
            title: 'ربط Firebase (اختياري)',
            color: AppTheme.extraPurpleFor(context),
            subtitle: 'لبط حساب الموظف بحساب Firebase Auth',
          ),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  controller: _userUidCtrl,
                  label: 'User UID',
                  icon: Icons.fingerprint_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildTextField(
                  controller: _userEmailCtrl,
                  label: 'User Email',
                  icon: Icons.alternate_email_rounded,
                  keyboardType: TextInputType.emailAddress,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }


  // ============================================================
  // Section 5: Additional
  // ============================================================

  Widget _buildSection5_Additional() {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            icon: Icons.info_rounded,
            title: 'بيانات إضافية',
            color: AppTheme.extraTealFor(context),
          ),
          _buildTextField(
            controller: _emergencyCtrl,
            label: 'جهة اتصال طارئ',
            icon: Icons.emergency_rounded,
            maxLength: 50,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  controller: _bankNameCtrl,
                  label: 'اسم البنك',
                  icon: Icons.account_balance_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildTextField(
                  controller: _bankAccountCtrl,
                  label: 'رقم الحساب',
                  icon: Icons.credit_score_rounded,
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildTextField(
            controller: _notesCtrl,
            label: 'ملاحظات',
            icon: Icons.notes_rounded,
            maxLines: 3,
          ),
        ],
      ),
    );
  }


  // ============================================================
  // Bottom buttons
  // ============================================================

  Widget _buildBottomButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _isSaving ? null : _cancel,
            icon: Icon(
              Icons.close_rounded,
              color: AppTheme.textMutedFor(context),
              size: 18,
            ),
            label: Text(
              'إلغاء',
              style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMutedFor(context),
                fontWeight: FontWeight.bold,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: GlassStyle.line24For(context)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    _isEditMode
                        ? Icons.update_rounded
                        : Icons.save_rounded,
                    size: 18,
                  ),
            label: Text(
              _isSaving
                  ? 'جاري الحفظ...'
                  : (_isEditMode ? 'تحديث' : 'حفظ'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentFor(context),
              foregroundColor: AppTheme.onAccentFor(context),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }


  // ============================================================
  // No permission screen
  // ============================================================

  Widget _buildNoPermissionScreen() {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          "إضافة / تعديل موظف",
          style: TextStyle(
            fontFamily: 'Cairo',
            color: AppTheme.textMainFor(context),
          ),
        ),
        centerTitle: true,
        backgroundColor: AppTheme.appBarBg,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textMainFor(context)),
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.dashGradientMain(context),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 64,
                  color: AppTheme.textMutedFor(context),
                ),
                const SizedBox(height: 12),
                Text(
                  'ليس لديك صلاحية إدارة الموظفين',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// نهاية ملف employee_form_page.dart
//
// الملف بيحتوي على:
// - 15 TextEditingController (كل حقل)
// - 6 dropdown values (gender, contract, status, branch, 3 dates)
// - 5 أقسام (Basic, Personal, Work, Firebase, Additional)
// - Validations: code/name مطلوبين، email صيغة، nationalId 14 رقم، salary رقم
// - فحص تكرار الكود قبل الحفظ
// - Alert قبل الإلغاء لو فيه تعديلات
// - فحص صلاحية canManageEmployees
// ============================================================
#  Billing Management System (MySQL DBMS Project)

##  Overview
This project is a **Billing Management System** implemented using **MySQL**.  
It simulates a real-world billing workflow including customer handling, product management, invoice generation, and reporting.

The project demonstrates strong concepts of **DBMS and SQL**, including stored procedures, functions, cursors, and constraints.

---

##  Features

-  Invoice generation with multiple items  
-  Product and stock management  
-  Customer management system  
-  Automatic calculation of:
  - Subtotal  
  - Discount  
  - Tax  
  - Grand Total
-  Invoice cancellation with stock restoration  
-  Sales reports and analytics  
-
-  Error logging system  

---

##  Database Structure

### Tables Used:
- `users` – system users (admin/cashier)
- `customers` – customer details
- `products` – product catalog
- `invoices` – billing records
- `invoice_items` – items in each invoice
- `invoice_cart` – temporary cart
- `error_log` – error tracking

---

##  Stored Procedures

- `sp_add_product` – Add new product  
- `sp_add_customer` – Add new customer  
- `sp_create_invoice_no_signals` – Create invoice with validation  
- `sp_cancel_invoice` – Cancel invoice  
- `sp_get_invoice` – Fetch invoice details  
- `sp_daily_sales_report` – Generate sales report  
- `sp_customers_above_threshold` – High-value customers  

---

##  Functions

- `fn_calc_discount` – Calculates discount  
- `fn_calc_tax` – Calculates tax  
- `fn_calc_grand` – Calculates final amount  

---

##  Technologies Used
- MySQL  
- SQL (DDL, DML)  
- Stored Procedures & Functions  

---
## Author
- Navya Garg ( https://github.com/Navya241006 )
- Kartik Garg ( https://github.com/kartikgarg090306-tech )

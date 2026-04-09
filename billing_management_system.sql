
DROP DATABASE IF EXISTS billing_db;
CREATE DATABASE billing_db;
USE billing_db;

CREATE TABLE users (
  user_id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(50) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  role ENUM('admin','cashier') NOT NULL DEFAULT 'cashier',
  full_name VARCHAR(100),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE customers (
  customer_id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  phone VARCHAR(20),
  email VARCHAR(100) UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE products (
  product_id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(150) NOT NULL,
  category VARCHAR(50),
  price DECIMAL(10,2) NOT NULL,
  stock_qty INT NOT NULL DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(name, category)
);

CREATE TABLE invoices (
  invoice_id INT AUTO_INCREMENT PRIMARY KEY,
  invoice_date DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  customer_id INT,
  user_id INT NOT NULL,
  subtotal DECIMAL(12,2) NOT NULL DEFAULT 0,
  discount_amt DECIMAL(12,2) NOT NULL DEFAULT 0,
  tax_amt DECIMAL(12,2) NOT NULL DEFAULT 0,
  grand_total DECIMAL(12,2) NOT NULL DEFAULT 0,
  status ENUM('active','cancelled') NOT NULL DEFAULT 'active',
  notes TEXT,
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE SET NULL,
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE RESTRICT
);

CREATE TABLE invoice_items (
  item_id INT AUTO_INCREMENT PRIMARY KEY,
  invoice_id INT NOT NULL,
  product_id INT NOT NULL,
  qty INT NOT NULL,
  unit_price DECIMAL(10,2) NOT NULL,
  line_total DECIMAL(12,2) NOT NULL,
  FOREIGN KEY (invoice_id) REFERENCES invoices(invoice_id) ON DELETE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(product_id) ON DELETE RESTRICT
);

DROP TABLE IF EXISTS invoice_cart;
CREATE TABLE invoice_cart (
  product_id INT NOT NULL,
  qty INT NOT NULL,
  CHECK (qty > 0)
);

DROP TABLE IF EXISTS error_log;
CREATE TABLE IF NOT EXISTS error_log (
  err_id INT AUTO_INCREMENT PRIMARY KEY,
  err_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  context VARCHAR(100),
  message TEXT
);

CREATE INDEX idx_invoice_date ON invoices(invoice_date);
CREATE INDEX idx_invoice_customer ON invoices(customer_id);

DELIMITER $$
CREATE FUNCTION fn_calc_discount(percent DECIMAL(5,2), amount DECIMAL(12,2))
RETURNS DECIMAL(12,2)
DETERMINISTIC
BEGIN
  IF percent < 0 OR percent > 100 THEN
    RETURN 0;
  END IF;
  RETURN ROUND((percent/100) * amount, 2);
END$$

CREATE FUNCTION fn_calc_tax(rate DECIMAL(5,2), amount DECIMAL(12,2))
RETURNS DECIMAL(12,2)
DETERMINISTIC
BEGIN
  IF rate < 0 THEN
    RETURN 0;
  END IF;
  RETURN ROUND((rate/100) * amount, 2);
END$$

CREATE FUNCTION fn_calc_grand(amount DECIMAL(12,2), discount_amt DECIMAL(12,2), tax_amt DECIMAL(12,2))
RETURNS DECIMAL(12,2)
DETERMINISTIC
BEGIN
  RETURN ROUND(amount - discount_amt + tax_amt, 2);
END$$
DELIMITER ;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_add_product$$
CREATE PROCEDURE sp_add_product(
  IN p_name VARCHAR(150),
  IN p_category VARCHAR(50),
  IN p_price DECIMAL(10,2),
  IN p_stock INT
)
BEGIN
  INSERT INTO products(name, category, price, stock_qty)
  VALUES (p_name, p_category, p_price, p_stock);
END$$

DROP PROCEDURE IF EXISTS sp_add_customer$$
CREATE PROCEDURE sp_add_customer(
  IN p_name VARCHAR(100),
  IN p_phone VARCHAR(20),
  IN p_email VARCHAR(100)
)
BEGIN
  INSERT INTO customers(name, phone, email)
  VALUES (p_name, p_phone, p_email);
END$$

DROP PROCEDURE IF EXISTS sp_get_invoice$$
CREATE PROCEDURE sp_get_invoice(IN p_invoice_id INT)
BEGIN
  SELECT i.invoice_id, i.invoice_date, i.customer_id, c.name AS customer_name, c.phone, 
         i.user_id, u.username, i.subtotal, i.discount_amt, i.tax_amt, i.grand_total, i.status, i.notes
  FROM invoices i
  LEFT JOIN customers c ON i.customer_id = c.customer_id
  LEFT JOIN users u ON i.user_id = u.user_id
  WHERE i.invoice_id = p_invoice_id;
  SELECT ii.item_id, ii.product_id, p.name AS product_name, ii.qty, ii.unit_price, ii.line_total
  FROM invoice_items ii
  JOIN products p ON ii.product_id = p.product_id
  WHERE ii.invoice_id = p_invoice_id;
END$$

DROP PROCEDURE IF EXISTS sp_daily_sales_report$$
CREATE PROCEDURE sp_daily_sales_report(IN p_start DATE, IN p_end DATE)
BEGIN
  SELECT DATE(invoice_date) AS day, COUNT(*) AS invoices_count, SUM(grand_total) AS total_sales
  FROM invoices
  WHERE DATE(invoice_date) BETWEEN p_start AND p_end
    AND status = 'active'
  GROUP BY DATE(invoice_date)
  ORDER BY day;
END$$

DROP PROCEDURE IF EXISTS sp_customers_above_threshold$$
CREATE PROCEDURE sp_customers_above_threshold(IN p_threshold DECIMAL(12,2))
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE cust_id INT;
  DECLARE cust_name VARCHAR(100);
  DECLARE total_purchases DECIMAL(12,2);
  DECLARE cur CURSOR FOR
    SELECT c.customer_id, c.name, IFNULL(SUM(i.grand_total),0) AS total_purchases
    FROM customers c
    LEFT JOIN invoices i ON c.customer_id = i.customer_id
    WHERE i.status = 'active' OR i.status IS NULL
    GROUP BY c.customer_id, c.name
    HAVING total_purchases > p_threshold;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO cust_id, cust_name, total_purchases;
    IF done = 1 THEN
      LEAVE read_loop;
    END IF;
    SELECT cust_id AS customer_id, cust_name AS customer_name, total_purchases;
  END LOOP;
  CLOSE cur;
END$$

DROP PROCEDURE IF EXISTS sp_create_invoice_no_signals$$
CREATE PROCEDURE sp_create_invoice_no_signals(
  IN p_customer_id INT,
  IN p_user_id INT,
  IN p_discount_percent DECIMAL(5,2),
  IN p_tax_rate DECIMAL(5,2),
  OUT p_status INT,
  OUT p_message VARCHAR(255),
  OUT p_invoice_id INT,
  OUT p_subtotal DECIMAL(12,2),
  OUT p_discount_amt DECIMAL(12,2),
  OUT p_tax_amt DECIMAL(12,2),
  OUT p_grand_total DECIMAL(12,2)
)
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE c_prod_id INT;
  DECLARE c_qty INT;
  DECLARE unit_price DECIMAL(10,2);
  DECLARE stock_avail INT;
  DECLARE item_total DECIMAL(12,2);
  DECLARE cnt INT;
  DECLARE cur CURSOR FOR SELECT product_id, qty FROM invoice_cart;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  SET p_status = 1;
  SET p_message = 'Unknown error';
  SET p_invoice_id = NULL;
  SET p_subtotal = 0;
  SET p_discount_amt = 0;
  SET p_tax_amt = 0;
  SET p_grand_total = 0;
  proc_block: BEGIN
    IF (SELECT COUNT(*) FROM invoice_cart) = 0 THEN
      SET p_message = 'Cart is empty';
      INSERT INTO error_log(context, message) VALUES ('sp_create_invoice_no_signals','Cart is empty');
      LEAVE proc_block;
    END IF;
    OPEN cur;
    read_loop_check: LOOP
      FETCH cur INTO c_prod_id, c_qty;
      IF done = 1 THEN
        LEAVE read_loop_check;
      END IF;
      SELECT COUNT(*) INTO cnt FROM products WHERE product_id = c_prod_id;
      IF cnt = 0 THEN
        SET p_message = CONCAT('Product not found: id=', c_prod_id);
        INSERT INTO error_log(context, message) VALUES ('sp_create_invoice_no_signals', p_message);
        CLOSE cur;
        LEAVE proc_block;
      END IF;
      SELECT stock_qty, price INTO stock_avail, unit_price FROM products WHERE product_id = c_prod_id;
      IF stock_avail < c_qty THEN
        SET p_message = CONCAT('Insufficient stock for product id=', c_prod_id, ' (available=', stock_avail, ', required=', c_qty, ')');
        INSERT INTO error_log(context, message) VALUES ('sp_create_invoice_no_signals', p_message);
        CLOSE cur;
        LEAVE proc_block;
      END IF;
    END LOOP;
    CLOSE cur;
    INSERT INTO invoices(customer_id, user_id, subtotal, discount_amt, tax_amt, grand_total)
    VALUES (p_customer_id, p_user_id, 0, 0, 0, 0);
    SET @new_invoice = LAST_INSERT_ID();
    SET done = 0;
    SET p_subtotal = 0;
    OPEN cur;
    read_loop_insert: LOOP
      FETCH cur INTO c_prod_id, c_qty;
      IF done = 1 THEN
        LEAVE read_loop_insert;
      END IF;
      SELECT price INTO unit_price FROM products WHERE product_id = c_prod_id;
      SET item_total = ROUND(unit_price * c_qty, 2);
      INSERT INTO invoice_items(invoice_id, product_id, qty, unit_price, line_total)
      VALUES (@new_invoice, c_prod_id, c_qty, unit_price, item_total);
      UPDATE products
        SET stock_qty = stock_qty - c_qty
        WHERE product_id = c_prod_id;
      SET p_subtotal = ROUND(p_subtotal + item_total, 2);
    END LOOP;
    CLOSE cur;
    SET p_discount_amt = fn_calc_discount(p_discount_percent, p_subtotal);
    SET p_tax_amt = fn_calc_tax(p_tax_rate, p_subtotal - p_discount_amt);
    SET p_grand_total = fn_calc_grand(p_subtotal, p_discount_amt, p_tax_amt);
    UPDATE invoices
    SET subtotal = p_subtotal,
        discount_amt = p_discount_amt,
        tax_amt = p_tax_amt,
        grand_total = p_grand_total
    WHERE invoice_id = @new_invoice;
    SET p_status = 0;
    SET p_message = 'Invoice created successfully';
    SET p_invoice_id = @new_invoice;
  END proc_block;
END$$

DROP PROCEDURE IF EXISTS sp_cancel_invoice$$
CREATE PROCEDURE sp_cancel_invoice(
  IN p_invoice_id INT,
  OUT p_status INT,
  OUT p_message VARCHAR(255)
)
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE iid INT;
  DECLARE pid INT;
  DECLARE pqty INT;
  DECLARE cur CURSOR FOR SELECT item_id, product_id, qty FROM invoice_items WHERE invoice_id = p_invoice_id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  SET p_status = 1;
  SET p_message = 'Unknown error';
  proc_block: BEGIN
    IF (SELECT COUNT(*) FROM invoices WHERE invoice_id = p_invoice_id AND status = 'active') = 0 THEN
      SET p_message = 'Invoice not found or already cancelled';
      LEAVE proc_block;
    END IF;
    OPEN cur;
    read_loop: LOOP
      FETCH cur INTO iid, pid, pqty;
      IF done = 1 THEN
        LEAVE read_loop;
      END IF;
      UPDATE products SET stock_qty = stock_qty + pqty WHERE product_id = pid;
    END LOOP;
    CLOSE cur;
    UPDATE invoices SET status = 'cancelled' WHERE invoice_id = p_invoice_id;
    SET p_status = 0;
    SET p_message = 'Invoice cancelled and stock restored';
  END proc_block;
END$$
DELIMITER ;

INSERT INTO users(username, password_hash, role, full_name)
VALUES
('admin', 'adminpass', 'admin', 'Admin User'),
('cashier1', 'cashier1', 'cashier', 'Cashier One');

CALL sp_add_customer('Alice Kumar', '9876543210', 'alice@example.com');
CALL sp_add_customer('Rahul Singh', '9123456780', 'rahul@example.com');
CALL sp_add_customer('Sneha Sharma', '9000123456', 'sneha@example.com');

CALL sp_add_product('Pen', 'Stationery', 10.00, 100);
CALL sp_add_product('Notepad', 'Stationery', 45.00, 50);
CALL sp_add_product('Stapler', 'Office', 150.00, 20);
CALL sp_add_product('Eraser', 'Stationery', 5.00, 200);
CALL sp_add_product('Pencil', 'Stationery', 8.00, 150);
CALL sp_add_product('Marker', 'Stationery', 25.00, 80);

TRUNCATE TABLE invoice_cart;
INSERT INTO invoice_cart(product_id, qty) VALUES (1, 2), (3, 1);

SET @status = NULL;
SET @msg = NULL;
SET @inv_id = NULL;
SET @subtotal = NULL;
SET @disc = NULL;
SET @tax = NULL;
SET @grand = NULL;
CALL sp_create_invoice_no_signals(1, 2, 5.00, 18.00, @status, @msg, @inv_id, @subtotal, @disc, @tax, @grand);
SELECT @status AS status, @msg AS message, @inv_id AS invoice_id, @subtotal AS subtotal, @disc AS discount, @tax AS tax, @grand AS grand_total;

TRUNCATE TABLE invoice_cart;
INSERT INTO invoice_cart(product_id, qty) VALUES (2, 3), (5, 5);
CALL sp_create_invoice_no_signals(2, 2, 0.00, 18.00, @status, @msg, @inv_id, @subtotal, @disc, @tax, @grand);
SELECT @status AS status, @msg AS message, @inv_id AS invoice_id, @subtotal AS subtotal, @disc AS discount, @tax AS tax, @grand AS grand_total;

CALL sp_get_invoice(1);
CALL sp_get_invoice(2);

SET @cstat = NULL;
SET @cmsg = NULL;
CALL sp_cancel_invoice(2, @cstat, @cmsg);
SELECT @cstat AS cancel_status, @cmsg AS cancel_message;

CALL sp_daily_sales_report('2025-01-01', '2026-12-31');
CALL sp_customers_above_threshold(50.00);
SELECT product_id, name, stock_qty FROM products ORDER BY stock_qty ASC;
SELECT p.product_id, p.name, SUM(ii.qty) AS total_qty_sold
FROM invoice_items ii
JOIN products p ON ii.product_id = p.product_id
GROUP BY p.product_id, p.name
ORDER BY total_qty_sold DESC;

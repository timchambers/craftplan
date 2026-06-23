defmodule Craftplan.BottleImport.Queries do
  @moduledoc "GraphQL documents for the Bottle importer (field names verified against the schema)."

  def list_product_by_sku do
    """
    query($sku: String!) {
      listProducts(filter: {sku: {eq: $sku}}) {
        results { id sku price }
      }
    }
    """
  end

  def create_product do
    """
    mutation($input: CreateProductInput!) {
      createProduct(input: $input) {
        result { id sku price }
        errors { message shortMessage fields }
      }
    }
    """
  end

  def list_customer_by_phone do
    """
    query($phone: String!) {
      listCustomers(filter: {phone: {eq: $phone}}) {
        results { id phone email }
      }
    }
    """
  end

  def list_customer_by_email do
    """
    query($email: String!) {
      listCustomers(filter: {email: {eq: $email}}) {
        results { id phone email }
      }
    }
    """
  end

  def create_customer do
    """
    mutation($input: CreateCustomerInput!) {
      createCustomer(input: $input) {
        result { id phone email }
        errors { message shortMessage fields }
      }
    }
    """
  end

  def update_customer do
    """
    mutation($id: ID!, $input: UpdateCustomerInput!) {
      updateCustomer(id: $id, input: $input) {
        result { id }
        errors { message shortMessage fields }
      }
    }
    """
  end

  def list_bottle_orders do
    """
    query($after: String) {
      listOrders(filter: {invoiceNumber: {like: "BOTTLE-%"}}, first: 250, after: $after) {
        results { id invoiceNumber paymentStatus }
        endKeyset
      }
    }
    """
  end

  def create_order do
    """
    mutation($input: CreateOrderInput!) {
      createOrder(input: $input) {
        result { id invoiceNumber }
        errors { message shortMessage fields }
      }
    }
    """
  end

  def update_order_paid do
    """
    mutation($id: ID!, $paidAt: DateTime) {
      updateOrder(id: $id, input: {paymentStatus: PAID, paidAt: $paidAt}) {
        result { id paymentStatus }
        errors { message shortMessage fields }
      }
    }
    """
  end
end
